//
//  PersonaStage.swift
//  coursona
//
//  검수(화면 5)·거울(화면 6)이 공유하는 흉상 무대: `RealityView` 수명 밖에서 `BustEntity` 를 쥐고(초상 `PreviewHolder`
//  패턴), 카메라·조명·앵커를 만들고, 사진 텍스처·유령 룩·Persona 재현 에셋(헤어·셔츠·눈알·입안)을 붙인다.
//  원래 `InspectionView` 안의 `InspectionHolder` 였던 것을 T-808(거울 화면)에서 둘이 같이 쓰도록 꺼냈다.
//

import SwiftUI
import RealityKit
import CoursonaCore
import CoursonaFace
import CoursonaRig
import CoursonaIO
import CoursonaDrive

@MainActor
@Observable
final class PersonaStageHolder {
    var bust: BustEntity?
    private var anchor: Entity?
    private var textureApplied = false

    /// `RealityViewContent` 는 visionOS 전용, 다른 플랫폼은 `RealityViewCameraContent` — 둘 다 받으려고
    /// 공통 프로토콜(`RealityViewContentProtocol`)로 받는다(Apple 문서, 2026-10-06 `DocumentationSearch` 로 확인).
    func setup(content: some RealityViewContentProtocol, template: BustTemplate, identity: Identity) {
        guard bust == nil else { return }
        let anchor = Entity()
        // 초상(Chosang) `TemplatePreviewView.swift` 의 기본("orbit") 카메라와 같은 값 — `PrevizCameraSpec.contract`
        // 는 그 프로젝트에서도 "맨 흉상"(머리카락·옷 없음) previz QA 전용 모드에서만 쓰고(기본값 off), 평소
        // 보기 모드는 이 고정 카메라 + **anchor 를 Y -0.30 만큼 내려 얼굴을 시야 안으로 당기는 트릭**을 쓴다.
        // 이 화면은 그 두 번째(= 머리카락·옷 입은 완성 페르소나를 보여주는 실제 쓰임) 패턴을 그대로 가져왔어야
        // 하는데 카메라 값만 베끼고 이 anchor 오프셋을 빠뜨려서, 얼굴(Y≈0.3~0.5)이 항상 시야 위로 잘려 나갔다
        // (실기기 스크린샷 + Chosang 소스 대조로 확인한 회귀 — 한 번은 `PrevizCameraSpec.contract` 로 바꿔 봤지만
        // 그건 맨 흉상 전용 모드라 머리카락이 붙은 완성 페르소나에서는 카메라가 메시 안에 파묻혔다).
        anchor.position = SIMD3(0, -0.30, 0)
        content.add(anchor)
        self.anchor = anchor

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 34
        camera.position = SIMD3(0, 0.02, 1.05)
        camera.look(at: .zero, from: camera.position, relativeTo: nil)
        content.add(camera)

        let light = DirectionalLight()
        light.light.intensity = 2500
        light.look(at: .zero, from: SIMD3(0.5, 1.0, 1.2), relativeTo: nil)
        content.add(light)
        let fill = DirectionalLight()
        fill.light.intensity = 900
        fill.look(at: .zero, from: SIMD3(-1.0, 0.3, 0.8), relativeTo: nil)
        content.add(fill)

        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .init(red: 0.86, green: 0.68, blue: 0.58, alpha: 1))
        material.roughness = .init(floatLiteral: 0.55)
        material.metallic = .init(floatLiteral: 0)

        do {
            let b = try BustEntity(template: template, identity: identity, material: material, preferGPU: false)
            anchor.addChild(b.root)
            bust = b
        } catch {
            // BustEntity 생성 자체가 실패하는 건 템플릿·Identity 정점 수 불일치 같은 심각한 문제라
            // 조용히 묻지 않고 콘솔에 남긴다 — 사용자에게 보일 자리는 3단계 폴리시 패스에서 정리한다.
            print("[코르소나] PersonaStage BustEntity 생성 실패: \(error.localizedDescription)")
        }
    }

    /// 흉상이 생길 때까지 잠깐 기다린다 — `RealityView` 의 콘텐츠 클로저(`setup`)가 뷰의 `.task` 보다 늦게 실행될 수
    /// 있어서(실기기에서 재현: 텍스처가 영영 안 올라가고 민무늬 얼굴만 남음) 텍스처·에셋을 붙이기 전에 부른다.
    func waitForBust(maxMilliseconds: Int = 3000) async {
        var waited = 0
        while bust == nil, waited < maxMilliseconds {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 100
        }
    }

    func applyTexture(_ albedo: RGBAImage?) async {
        guard !textureApplied, let bust, let albedo, let cg = ImageCodec.cgImage(albedo) else { return }
        textureApplied = true
        guard let tex = try? await TextureResource(image: cg, withName: "coursona-albedo-\(ObjectIdentifier(bust).hashValue)",
                                                    options: .init(semantic: .color)) else { return }
        // 피부 머티리얼은 BustEntity 가 관리한다(유령 룩 셰이더가 켜져 있으면 그 위에 다시 입힌다 — D-308).
        bust.setSkinTexture(tex)
    }

    /// 유령 룩(디자인 PRD 룩·렌더링 원칙, Tasks.md D-308 ③): 흉상 피부를 반투명 + 프레넬 가장자리 소멸 + 하단 페이드로.
    /// 셰이더가 없는 환경(OS 26 metallib 미포함 등)이면 false 를 돌려주고 PBR 그대로 둔다.
    @discardableResult
    func setGhostLook(_ on: Bool) -> Bool {
        guard let bust else { return false }
        // 기본 불투명도는 1 — 검은 무대에서는 0.85 가 "반투명" 이 아니라 그냥 15% 어두워 보일 뿐이다(실측). 유령 느낌은
        // 프레넬 가장자리 소멸 + 하단 페이드가 낸다. 밝은 배경을 쓰게 되면 0.85 로 내린다(디자인 PRD D-308 ③).
        // 하단 페이드 14 cm: 셔츠 페이드(height01 0→0.18 ≈ 10.8 cm)보다 길게 두어 셔츠 아래로 흉상 피부 띠가 비치지 않게(실측 2026-10-07).
        return bust.setGhostLook(on, fresnel: 0.6, baseOpacity: 1, fadeHeight: 0.14)
    }

    /// 매 프레임 구동은 `FaceRigSystem`(ECS, `CoursonaApp.init` 에서 등록)이 맡는다 — 여기서는 그 컴포넌트의
    /// 입력(포즈 프리셋 = 클립 레이어, 움직임 on/off)만 바꾼다. 프리셋의 eyeLook 가중치는 시스템이 `applyGaze` 로
    /// 눈알 회전까지 이어 준다. 움직임을 끄면 머리 포즈를 중립으로 되돌린다(마지막 sway 자세에 멈추지 않게).
    func apply(pose: ArkitWeights, gaze: SIMD2<Float>, yaw: Float, motion: Bool) {
        guard let bust else { return }
        var rig = bust.root.components[FaceRigComponent.self] ?? FaceRigComponent()
        rig.clipWeights = pose.isEmpty ? nil : pose
        rig.autoBlink = motion
        rig.autoGaze = motion
        rig.idleMotion = motion ? 1 : 0
        bust.root.components.set(rig)
        bust.root.components.set(BustBinding(bust: bust))
        if !motion { bust.applyIdleMotion(yaw: 0, pitch: 0, roll: 0, breathScale: 1, bob: 0) }
        anchor?.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }

    /// 한글 문장 → 비짐 타임라인(`HangulViseme`) 을 큐에 넣는다. 말하는 동안 입술과 입안(치아·혀)이 같이 움직인다.
    func speak(_ text: String) {
        guard let bust, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var rig = bust.root.components[FaceRigComponent.self] ?? FaceRigComponent()
        rig.speak(text: text)
        bust.root.components.set(rig)
    }

    /// 마이크 레벨 → `FaceRigComponent.audioLevel`(음량 순환 비짐). 30 Hz 폴링(Soban `MouthSource` 와 같은 주기).
    private var mic: MicVisemeDriver?
    private var micTask: Task<Void, Never>?
    func setMic(_ on: Bool) {
        micTask?.cancel(); micTask = nil
        if !on {
            mic?.stop(); mic = nil
            if let bust, var rig = bust.root.components[FaceRigComponent.self] { rig.audioLevel = 0; bust.root.components.set(rig) }
            return
        }
        let driver = mic ?? MicVisemeDriver()
        mic = driver
        micTask = Task { [weak self] in
            await driver.start()
            while !Task.isCancelled {
                if let self, let bust = self.bust, var rig = bust.root.components[FaceRigComponent.self] {
                    rig.audioLevel = driver.level
                    bust.root.components.set(rig)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private var assetsAttached = false

    /// Persona 재현 에셋(D 절): `coursona_assets.json` + Template.usdz → `BustEntity.attachPersonaAssets`. 매니페스트가 없는
    /// 옛 템플릿은 `EyesMouth.usdz` → `attachEyesMouth` 폴백. 템플릿 캐시 확인은 디스크를 건드리므로 메인 밖에서.
    /// 머리색은 패키지 매니페스트 `hairTint`(T-704, 없으면 레퍼런스 갈색), 홍채색은 알베도에서 추정.
    /// `presence`: 정적 존재 마스크(정면 1 → 옆 → 뒤 0). 턴테이블 검수는 끄고, 정면 고정인 거울은 켠다.
    func attachPersonaAssets(package: CoursonaPackage, presence: Bool) async {
        guard let bust, !bust.hasEyesMouth, !assetsAttached else { return }
        assetsAttached = true
        guard let folder = try? await Task.detached(priority: .userInitiated, operation: { try TemplateStore.prepareDefault() }).value else { return }
        if let manifest = TemplateStore.loadAssetManifest(from: folder), let usdz = TemplateStore.templateUSDZURL(in: folder) {
            guard let root = try? await Entity(contentsOf: usdz) else { print("[코르소나] Template.usdz 로드 실패"); return }
            // Template.usdz 에 없는 프림(라이브러리 오브젝트)은 library/<prim>.usdz 를 같은 루트 아래에 붙여 한 번에 찾게 한다.
            for (_, entry) in manifest.assets where root.findEntity(named: entry.prim) == nil {
                guard let libURL = TemplateStore.libraryUSDZURL(named: entry.prim, in: folder),
                      let lib = try? await Entity(contentsOf: libURL) else { continue }
                lib.name = "Library_\(entry.prim)"
                root.addChild(lib)
            }
            var look = PersonaLook()
            look.presenceEnabled = presence
            if let t = package.manifest.hairTint, t.count == 3 { look.hairTint = SIMD3(t[0], t[1], t[2]) }
            else if let albedo = package.albedo, let h = bust.estimateHairColor(from: albedo) { look.hairTint = h }   // 옛 패키지(hairTint 없음)
            if let albedo = package.albedo { look.irisColor = bust.estimateIrisColor(from: albedo) }
            print("[코르소나] Persona 룩: 머리 틴트 \(look.hairTint) · 홍채 \(String(describing: look.irisColor))")
            let report = await bust.attachPersonaAssets(from: root, manifest: manifest, texturesFolder: TemplateStore.texturesFolder(in: folder), look: look)
            print("[코르소나] Persona 에셋: \(report)")
            return
        }
        guard let url = TemplateStore.eyesMouthURL(in: folder), let loaded = try? await Entity(contentsOf: url) else { return }
        bust.attachEyesMouth(loaded)
        if let albedo = package.albedo, let iris = bust.estimateIrisColor(from: albedo) { bust.setIrisColor(iris) }
    }
}
