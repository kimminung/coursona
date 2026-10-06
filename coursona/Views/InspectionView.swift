//
//  InspectionView.swift
//  coursona
//
//  화면 5(UXPRD) — 검수. 뷰포트가 화면의 주인공(UXPRD §4)이고 컨트롤은 그 아래 얇은 바 — 포즈 세그먼트·
//  입체감 토글·품질 카드(접힘/펼침). 초상(Chosang) `TemplatePreviewView.swift` 의 `RealityView` 패턴
//  (엔티티는 `@Observable` 홀더에, SwiftUI 뷰 값 타입 수명 밖에 둔다)을 재사용한다.
//  자기교차("겹침") 배지는 숫자(RMS 등)를 기본 화면에 안 보여주고 "겹침 없음 ✓" 결론만 보여준다(UXPRD §4) —
//  자세히 보려면 품질 카드를 펼친다.
//

import SwiftUI
import RealityKit
import CoursonaCore
import CoursonaFace
import CoursonaRig
import CoursonaSplat
import CoursonaIO

private enum PosePreset: String, CaseIterable, Identifiable {
    case neutral = "무표정", smile = "미소", eyesClosed = "눈 감기", mouthOpen = "입 벌림", gaze = "시선"
    var id: String { rawValue }

    var weights: ArkitWeights {
        var w = ArkitWeights()
        switch self {
        case .neutral: break
        case .smile: w[.mouthSmileLeft] = 1; w[.mouthSmileRight] = 1
        case .eyesClosed: w[.eyeBlinkLeft] = 1; w[.eyeBlinkRight] = 1
        case .mouthOpen: w[.jawOpen] = 0.6
        case .gaze: w[.eyeLookOutLeft] = 0.7; w[.eyeLookInRight] = 0.7
        }
        return w
    }

    var gaze: SIMD2<Float> { self == .gaze ? SIMD2(0.7, 0) : .zero }
}

struct InspectionView: View {
    let package: CoursonaPackage
    let template: BustTemplate

    @State private var holder = InspectionHolder()
    @State private var pose: PosePreset = .neutral
    @State private var showSplats = true
    @State private var showQualityDetail = false
    @State private var flippedTriangleCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RealityView { content in
                    holder.setup(content: content, template: template, identity: package.identity)
                    holder.apply(pose: pose.weights, gaze: pose.gaze, showSplats: showSplats, records: package.splats)
                } update: { _ in
                    holder.apply(pose: pose.weights, gaze: pose.gaze, showSplats: showSplats, records: package.splats)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                if let count = flippedTriangleCount {
                    StatusPill(text: count == 0 ? "겹침 없음 ✓" : "겹침 의심 \(count)곳",
                              kind: count == 0 ? .success : .warning)
                        .padding(12)
                }
                TierBadge(tier: package.manifest.tier ?? .b)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(spacing: 14) {
                Picker("포즈", selection: $pose) {
                    ForEach(PosePreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)

                Toggle("입체감(스플랫)", isOn: $showSplats)
                    .onChange(of: showSplats) { _, on in if !on { holder.bust?.hideOutsideFace() } }

                qualityCard
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .background(Color.coursonaBackground)
        .navigationTitle(package.manifest.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SaveShareView(package: package)
                } label: {
                    Label("저장·보내기", systemImage: "square.and.arrow.up")
                }
            }
        }
        .task {
            flippedTriangleCount = computeFlippedTriangles()
            // `RealityView` 의 콘텐츠 클로저(`holder.setup`, `holder.bust` 를 채운다)가 이 `.task` 보다 늦게
            // 실행될 수 있다 — 그러면 `applyTexture` 가 `bust == nil` 로 조용히 아무것도 안 하고 끝나고,
            // 재시도가 없어 사진 텍스처가 영영 안 올라가고 기본(살구색) 머티리얼만 남는다(실기기에서 재현:
            // 매번 똑같은 민무늬 얼굴). `bust` 가 생길 때까지 잠깐 기다렸다가 적용한다.
            var waited = 0
            while holder.bust == nil, waited < 30 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            await holder.applyTexture(package.albedo)
        }
    }

    private var qualityCard: some View {
        DisclosureGroup(isExpanded: $showQualityDetail) {
            if let q = package.manifest.textureQuality {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "관측 비율 %.0f%% · 채움 %.0f%% · 접합 단차 %.1f/255", q.observedRatio * 100, q.filledRatio * 100, q.seamDelta))
                    Text(String(format: "빌드 시간 %.1f초", q.buildSeconds))
                    if let count = flippedTriangleCount { Text("자기교차 의심 삼각형 \(count)개") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            } else {
                Text("품질 정보 없음").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                TierBadge(tier: package.manifest.tier ?? .b)
                Text(summarySentence).font(.subheadline)
                Spacer()
            }
        }
    }

    private var summarySentence: String {
        guard let q = package.manifest.textureQuality else { return "품질 정보 없음" }
        if q.observedRatio > 0.65 { return "실제로 찍은 모습이 대부분 그대로 반영됐어요" }
        return "일부는 추정해서 채웠어요"
    }

    private func computeFlippedTriangles() -> Int {
        var fitted = template
        if package.identity.positions.count == template.vertexCount { fitted.positions = package.identity.positions }
        let capped = CapBuilder.addingCaps(to: fitted)
        return SelfIntersectionCheck.check(capped).reduce(0) { $0 + $1.flippedTriangles }
    }
}

/// RealityView 수명 밖에서 BustEntity 를 쥔다(초상 PreviewHolder 와 같은 패턴).
@MainActor
@Observable
private final class InspectionHolder {
    var bust: BustEntity?
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
            // 검수 화면에서 BustEntity 생성 자체가 실패하는 건 템플릿·Identity 정점 수 불일치 같은 심각한 문제라
            // 조용히 묻지 않고 콘솔에 남긴다 — 사용자에게 보일 자리는 3단계 폴리시 패스에서 정리한다.
            print("[코르소나] InspectionView BustEntity 생성 실패: \(error.localizedDescription)")
        }
    }

    func applyTexture(_ albedo: RGBAImage?) async {
        guard !textureApplied, let bust, let albedo, let cg = ImageCodec.cgImage(albedo) else { return }
        textureApplied = true
        guard let tex = try? await TextureResource(image: cg, withName: "coursona-albedo-\(ObjectIdentifier(bust).hashValue)",
                                                    options: .init(semantic: .color)) else { return }
        guard var mc = bust.model.components[ModelComponent.self], !mc.materials.isEmpty else { return }
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(texture: .init(tex))
        mat.roughness = .init(floatLiteral: 0.55)
        mat.metallic = .init(floatLiteral: 0)
        mc.materials[0] = mat
        bust.model.components[ModelComponent.self] = mc
    }

    func apply(pose: ArkitWeights, gaze: SIMD2<Float>, showSplats: Bool, records: [SplatRecord]?) {
        guard let bust else { return }
        bust.update(weights: pose)
        bust.applyGaze(gaze)
        if showSplats { bust.applySplatRecords(records ?? []) }
    }
}

#Preview {
    Text("InspectionView 는 실제 CoursonaPackage 가 있어야 미리보기가 됩니다 — BuildProgressView 를 통해 확인하세요.")
        .padding()
}
