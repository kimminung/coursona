//
//  PersonaAssets.swift
//  CoursonaRig
//
//  D 절(Tasks.md, Persona 재현 에셋) 앱 쪽: `coursona_assets.json`(단일 진입점, AssetContract §4·§8) → Template.usdz 안의
//  `Hair_long_wave` · `Shoulders_shirt` · `Eye_L` · `Eye_R` · `Mouth_Inner` 프림을 **이름으로** 찾아 `BustEntity` 에 붙이고,
//  머티리얼을 역할(role)별로 앱이 정한 색·불투명도로 바꾼다(블렌더 에셋은 색 없는 틀 — §1).
//
//  부착(D-301 RigidAttach): 지금 머리 회전은 스켈레톤이 아니라 `model.transform` 근사(BustEntity 머리말 "스키닝은 M5")라,
//  Head 강체 에셋은 `model` 의 자식으로 두면 머리 포즈·숨쉬기를 그대로 따라간다. 눈은 피팅된 눈 중심 피벗, 입안은 피팅된
//  입 중심 피벗 — `attachEyesMouth` 와 같은 수학. Root·Neck 스킨인 셔츠도 지금은 Bust 어깨와 같은 근사로 `model` 아래
//  (M5 스키닝이 오면 둘 다 같이 바뀐다).
//
//  presence(D-310): uv1 = (presence, height01) 은 **앱이 bust 공간 정점으로 항상 다시 굽는다** — 블렌더가 구운 uv1 을
//  믿지 않는 이유는 RealityKit 이 USD UV 의 V 를 뒤집어 읽어(Apple 문서) height01 이 뒤집힐 수 있기 때문. 식은 같다(§5).
//  셰이더(`PersonaSurfaceShader`, 앱 타깃의 PersonaSurface.metal)가 있으면 uv1·프레넬·하단 페이드로 불투명도를 만들고,
//  없으면(패키지 테스트·CLI) PBR 폴백(헤어는 알파 마스크 텍스처로 실루엣만).
//

import Foundation
import RealityKit
import simd
import CoreGraphics
import ImageIO
import CoursonaCore

/// 앱이 정하는 룩 값(사진 기반 색은 호출자가 넣는다 — 패키지 매니페스트 `hairTint`, `estimateIrisColor`).
public struct PersonaLook: Sendable {
    /// 머리색(sRGB 0…1). 틴트 = 목표색 ÷ 텍스처 평균 회색(0.63) — AssetContract §2.
    public var hairTint = SIMD3<Float>(0.36, 0.25, 0.17)
    public var hairTextureMeanGray: Float = 0.63
    public var hairOpacityThreshold: Float = 0.45
    /// 셔츠 색(#1E2A44 네이비, PRD §에셋 스펙 2). 어깨 사진 평균색이 생기면 그걸로.
    public var clothColor = SIMD3<Float>(0.118, 0.165, 0.267)
    public var irisColor: SIMD3<Float>? = nil
    /// 셰이더 불투명도 = baseOpacity × presence × 하단 페이드 × (1 − fresnel × edge). 유령 룩(D-308) 전엔 1.
    public var baseOpacity: Float = 1
    public var fresnelStrength: Float = 0.6
    /// 셔츠 하단 페이드(D-304) — height01(= y/0.60) 구간. 셔츠는 y 0(가슴 절단면)…≈0.30(칼라) → 0…0.5.
    public var shirtFadeHeight01 = SIMD2<Float>(0, 0.18)
    public var useGhostShader = true
    /// presence(정적 존재 마스크: 정면 1 → 옆 0.46 → 뒤 0, AssetContract §5)를 uv1.x 에 굽는다. 턴테이블 검수처럼 옆·뒤를 봐야 하면
    /// 끈다(1 로 구움) — 켜 두면 3/4 뷰에서 먼 쪽 머리·셔츠가 사라져 속이 비어 보인다(실측 2026-10-07).
    public var presenceEnabled = true
    /// 두피 캡 테두리(헤어라인) 페이드 폭(m) — 캡 가장자리가 직선으로 끊겨 가발처럼 보이지 않게(2026-10-08). 0 이면 끔.
    public var hairlineFadeWidth: Float = 0.02
    public init() {}
}

public struct PersonaAssetReport: Sendable, CustomStringConvertible {
    public struct Item: Sendable {
        public var prim: String
        public var kind: String
        public var attached: Bool
        public var triangles: Int
        public var expectedTriangles: Int?
        public var note: String
    }
    public var items: [Item] = []
    public var notes: [String] = []
    public var shader = false
    public var attachedCount: Int { items.filter(\.attached).count }
    public var description: String {
        var s = "에셋 \(attachedCount)/\(items.count) 부착 · 셰이더 \(shader ? "O" : "X")"
        for i in items { s += "\n  · \(i.prim)(\(i.kind)): \(i.attached ? "O" : "X") 삼각형 \(i.triangles)" + (i.expectedTriangles.map { "/\($0)" } ?? "") + (i.note.isEmpty ? "" : " — \(i.note)") }
        for n in notes { s += "\n  " + n }
        return s
    }
}

extension BustEntity {
    /// Head 조인트 레스트 위치(흉상 공간) — template.json `boneRest.Head`, 없으면 계약값 (0, 0.36, 0).
    var headJointRest: SIMD3<Float> {
        if let p = template.manifest.boneRest["Head"], p.count == 3 { return SIMD3(p[0], p[1], p[2]) }
        return SIMD3(0, 0.36, 0)
    }

    /// `coursona_assets.json` 의 에셋을 Template.usdz(`root`, 아직 장면에 안 붙은 로드 결과)에서 찾아 붙인다.
    /// 한 번만 — 눈/입이 붙으면 `hasEyesMouth` 가 켜지고 캡은 투명해진다.
    @discardableResult
    public func attachPersonaAssets(from root: Entity, manifest: CoursonaAssetManifest, texturesFolder: URL, look: PersonaLook = PersonaLook()) async -> PersonaAssetReport {
        var report = PersonaAssetReport()
        guard manifest.isSupported else { report.notes.append("schema '\(manifest.schema)' 미지원(필요 \(CoursonaAssetManifest.supportedSchema))"); return report }
        guard !hasEyesMouth else { report.notes.append("이미 부착됨"); return report }
        let shader = look.useGhostShader ? PersonaSurfaceShader.shared : nil
        report.shader = shader != nil
        let textures = PersonaTextureCache(folder: texturesFolder)
        let m = template.manifest
        let restEyeL = SIMD3<Float>(m.eyeL[0], m.eyeL[1], m.eyeL[2]), restEyeR = SIMD3<Float>(m.eyeR[0], m.eyeR[1], m.eyeR[2])
        let eyeScale = max(0.5, min(2.0, identity.eyeRadius / max(1e-4, m.eyeRadius)))
        var eyesAttached = false, mouthAttached = false
        // 헤어·셔츠(이하 "default" 분기)를 **레스트 흉상 → 피팅 흉상** 으로 옮기는 변환(2026-10-08, 실기기 TrueDepth 캡처로 확인).
        // 사진(B·C 등급)은 `identity.scale` 이 1 로 고정이라(TechPRD §6.3) 거의 항등이지만, A 등급은 F1/F3 이 실제 깊이로
        // 스케일 s(실측 1.06)를 구해 흉상이 커진다. 1차 보정(Head 조인트 기준 **균일** 스케일)은 피터가 실제로 한 변환과
        // 달라 두 가지 결함을 남겼다(시뮬레이터 검수, 2026-10-08):
        //  · 셔츠 — `HeadPropagator` 는 어깨를 **x·z 만** 원점 기준 s 배(y 그대로) 넓히는데, 균일 스케일은 셔츠의 어깨 경사선을
        //    y 0.36 기준으로 7 mm 끌어내려 경사 구간에서 흉상 어깨가 최대 15 mm 삐져나왔다(양쪽 어깨 삼각형 구멍).
        //  · 헤어 — 머리는 전역 유사변환(스케일 1.046 + 평행이동 −25 mm y)로 움직였는데 균일 스케일은 머리카락을 정수리 위
        //    15 mm·앞 12 mm 로 띄웠다(가발처럼 얹힌 느낌).
        // 그래서 변환을 흉상 정점에서 직접 읽는다: 두피 그룹의 유사변환(`Procrustes`)으로 Head 강체 에셋을, 어깨 그룹의 축별
        // 최소제곱 스케일+이동으로 셔츠를 옮긴다 — 피터가 무엇을 했든 그 결과(정점)에 맞춘다.
        let headFit = headRestToFitted()
        let shoulderFit = shoulderRestToFitted()
        var scalePivots: [AssetEntry.Kind: Entity] = [:]

        for (_, entry) in manifest.assets.sorted(by: { $0.key < $1.key }) {
            var item = PersonaAssetReport.Item(prim: entry.prim, kind: entry.kind.rawValue, attached: false, triangles: 0, expectedTriangles: entry.triangleCount, note: "")
            defer { report.items.append(item) }
            guard var prim = root.findEntity(named: entry.prim) else { item.note = "프림 없음(조인트 이름만 있거나 내보내기에서 빠짐)"; continue }
            var modelEntity = Self.firstModelEntity(in: prim)
            if modelEntity == nil, let merged = Self.libraryModelEntity(for: entry.prim, in: root) {
                // 스킨 메시(셔츠)는 RealityKit 이 SkelRoot(Armature) 엔티티 하나로 합쳐 프림 이름 아래엔 ModelComponent 가 없다 —
                // library/<prim>.usdz 에는 그 메시 하나뿐이니 그 루트의 모델 엔티티가 곧 이 에셋이다(실측 2026-10-07: Shoulders_shirt).
                modelEntity = merged; prim = merged
            }
            guard var modelEntity else { item.note = "ModelComponent 없음"; continue }
            if entry.kind != .eye && entry.kind != .mouth, modelEntity.components[SkeletalPosesComponent.self] != nil, let mc = modelEntity.components[ModelComponent.self] {
                // 스킨 메시(셔츠)는 RealityKit 이 스켈레톤 포즈로 그린다. 아래에서 메시를 uv1 포함 LowLevelMesh 로 갈아 끼우면 스키닝
                // 데이터가 없어지므로, 스켈레톤 없는 일반 ModelEntity 로 옮겨 **바인드 좌표 그대로** 그린다(지금은 어차피 스키닝을
                // 안 쓴다 — 머리말 "스키닝은 M5", 머리 회전은 `model.transform` 이 통째로 돌린다). 눈·입안은 그대로 둔다(블렌드셰이프).
                let plain = ModelEntity(mesh: mc.mesh, materials: mc.materials)
                plain.name = "\(entry.prim)_bind"
                plain.transform = Transform(matrix: modelEntity.transformMatrix(relativeTo: nil))
                root.addChild(plain)
                modelEntity.removeFromParent()
                modelEntity = plain; prim = plain
            }
            item.triangles = Self.triangleCount(of: modelEntity)
            if let exp = entry.triangleCount, exp > 0, exp != item.triangles { item.note = "삼각형 수 불일치(매니페스트 \(exp))" }

            // 흉상 공간 변환(USD 스테이지·아마추어 변환 포함) — root 는 아직 부모가 없으므로 nil 기준 = root 포함.
            let toBust = prim.transformMatrix(relativeTo: nil)
            let meshToBust = modelEntity.transformMatrix(relativeTo: nil)
            // 헤어: 두피 캡(faceRanges.cap) 테두리(= 헤어라인·구레나룻·목덜미)를 `hairlineFadeWidth` 폭으로 투명하게 녹여
            // 이마 피부가 머리카락 속으로 서서히 이어지게 한다 — 캡 가장자리가 직선으로 딱 끊겨 가발처럼 보였다(실측 2026-10-08).
            let capRanges = (entry.kind == .hair) ? (entry.faceRanges?["cap"]?.ranges ?? []) : []
            if entry.kind != .eye && entry.kind != .mouth {
                // 헤어·셔츠: uv1(presence × 헤어라인 페이드, height01)을 LowLevelMesh 로 다시 굽고, 두피 캡은 별도 파트(머티리얼 1)로 —
                // 캡 칸 텍스처가 카드보다 밝아 정수리에 회색 판이 비쳤다(실측 2026-10-08). 헤어라인 페이드: 캡 테두리(=헤어라인)에서
                // `hairlineFadeWidth` 안의 정점(카드 뿌리 포함)을 투명하게 녹여 이마 피부가 머리카락으로 서서히 이어지게 한다.
                if !Self.bakePresenceUV1(into: modelEntity, meshToBust: meshToBust, params: manifest.presence, headJoint: headJointRest, presence: look.presenceEnabled,
                                         edgeFadeRanges: capRanges, edgeFadeWidth: look.hairlineFadeWidth, splitRanges: capRanges, splitMaterialIndex: 1) {
                    item.note += (item.note.isEmpty ? "" : " · ") + "uv1 굽기 실패(블렌더 uv1 사용)"
                }
            }

            switch entry.kind {
            case .eye:
                let isLeft = entry.prim.hasSuffix("_L") || entry.attach.bone == "Eye_L"
                let pivot = Entity(); pivot.name = isLeft ? "EyePivot_L" : "EyePivot_R"
                let center = isLeft ? identity.eyeCenterL : identity.eyeCenterR
                let back = eyeDepthCorrection(center: center, radius: m.eyeRadius * eyeScale)
                pivot.position = center - SIMD3(0, 0, back)
                if back > 0 { item.note += (item.note.isEmpty ? "" : " · ") + String(format: "눈알 %.1f mm 뒤로(눈 감기 뚫림 방지)", back * 1000) }
                pivot.scale = SIMD3(repeating: eyeScale)
                model.addChild(pivot)
                Self.reparent(prim, under: pivot, matrix: toBust, restCenter: isLeft ? restEyeL : restEyeR)
                if isLeft { eyePivotL = pivot } else { eyePivotR = pivot }
                eyesAttached = true
            case .mouth:
                let pivot = Entity(); pivot.name = "MouthInnerPivot"
                pivot.position = fittedMouthCenter
                pivot.scale = SIMD3(repeating: max(0.6, min(1.6, identity.scale)))
                model.addChild(pivot)
                Self.reparent(prim, under: pivot, matrix: toBust, restCenter: restMouthCenter)
                if let me = modelEntity as? ModelEntity {
                    let comp = BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: me.model?.mesh ?? MeshResource.generateBox(size: 0.001)))
                    if comp.weightSet.contains(where: { !$0.weightNames.isEmpty }) { me.components.set(comp) }
                    else { item.note += (item.note.isEmpty ? "" : " · ") + "블렌드셰이프 없음" }
                    mouthInner = me
                } else { item.note += (item.note.isEmpty ? "" : " · ") + "ModelEntity 아님(셰이프키 구동 불가)" }
                mouthAttached = true
            default:
                // Head 강체(헤어·안경·수염) 와 Root·Neck 스킨(셔츠) 모두 지금은 model 아래 — 머리말 참고.
                // 피벗 변환 = 레스트 흉상 → 피팅 흉상(위 주석). 사진 등급이면 거의 항등이라 기존과 같다.
                let isShoulders = entry.kind == .shoulders
                let pivot = scalePivots[entry.kind] ?? {
                    let p = Entity(); p.name = "PersonaFitPivot_\(entry.kind.rawValue)"
                    p.transform = isShoulders
                        ? Transform(scale: shoulderFit.scale, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), translation: shoulderFit.offset)
                        : Transform(scale: SIMD3(repeating: headFit.scale), rotation: headFit.rotation, translation: headFit.translation)
                    model.addChild(p); scalePivots[entry.kind] = p
                    return p
                }()
                Self.reparent(prim, under: pivot, matrix: toBust, restCenter: .zero)
                item.note += (item.note.isEmpty ? "" : " · ") + (isShoulders
                    ? String(format: "어깨 맞춤 ×(%.3f, %.3f, %.3f)", shoulderFit.scale.x, shoulderFit.scale.y, shoulderFit.scale.z)
                    : String(format: "두피 유사변환 ×%.3f 이동 %.0f mm", headFit.scale, simd_length(headFit.translation) * 1000))
            }
            if entry.kind == .shoulders, shader != nil {
                // 셔츠: 하단 페이드 있는/없는 두 벌을 만들어 두고 유령 룩 상태에 따라 바꿔 끼운다(`applyClothFade`).
                // 유령 룩이 꺼지면 하단 페이드뿐 아니라 프레넬도 끈다 — 흉상이 불투명한데 셔츠 가장자리·밑단만 비치면 그 뒤 피부가
                // 테두리 빛·밑단 띠로 드러났다(시뮬레이터 검수 2026-10-08).
                var solidLook = look; solidLook.shirtFadeHeight01 = .zero; solidLook.fresnelStrength = 0
                let faded = await Self.materials(for: modelEntity, entry: entry, look: look, textures: textures, shader: shader)
                let solid = await Self.materials(for: modelEntity, entry: entry, look: solidLook, textures: textures, shader: shader)
                clothFadeSwap.append((modelEntity, faded, solid))
                if var mc = modelEntity.components[ModelComponent.self] { mc.materials = ghostLookOn ? faded : solid; modelEntity.components.set(mc) }
            } else {
                await Self.applyMaterials(to: modelEntity, entry: entry, look: look, textures: textures, shader: shader)
            }
            item.attached = true
        }

        if eyesAttached || mouthAttached {
            hasEyesMouth = true
            setCapsHidden(eyes: eyesAttached, mouth: mouthAttached)
            updateMouthInner(lastWeights)
        }
        return report
    }

    // MARK: 레스트 → 피팅 변환 (헤어·셔츠 배치)

    /// 두피(Scalp 그룹) 정점의 레스트 → 피팅 유사변환. Head 강체 에셋(헤어·안경·수염)을 피팅된 머리에 그대로 얹는 변환이다.
    /// 그룹이 없거나 퇴화하면 항등. (실측 A 등급: 스케일 1.046 · 회전 0.2° · 이동 (−1, −25, −12) mm · RMS 2.3 mm.)
    func headRestToFitted() -> SimilarityTransform {
        let ids = template.manifest.group(.scalp).filter { $0 < restPositions.count && $0 < template.positions.count }
        guard ids.count >= 3 else { return .identity }
        return Procrustes.fit(source: ids.map { restPositions[$0] }, target: ids.map { template.positions[$0] }, allowScale: true) ?? .identity
    }

    /// 어깨(Shoulders 그룹) 정점의 레스트 → 피팅 **축별** 스케일+이동(최소제곱, b = s·a + d). `HeadPropagator` 가 어깨를
    /// x·z 만 넓히므로(y 그대로) 유사변환이 아니라 축별로 읽어야 셔츠 어깨 경사선이 흉상과 같은 높이에 남는다.
    func shoulderRestToFitted() -> (scale: SIMD3<Float>, offset: SIMD3<Float>) {
        let ids = template.manifest.group(.shoulders).filter { $0 < restPositions.count && $0 < template.positions.count }
        guard ids.count >= 3 else { return (.one, .zero) }
        var scale = SIMD3<Float>.one, offset = SIMD3<Float>.zero
        let n = Float(ids.count)
        for axis in 0..<3 {
            var sa: Float = 0, sb: Float = 0, saa: Float = 0, sab: Float = 0
            for i in ids { let a = restPositions[i][axis], b = template.positions[i][axis]; sa += a; sb += b; saa += a * a; sab += a * b }
            let den = n * saa - sa * sa
            guard abs(den) > 1e-9 else { continue }
            let s = (n * sab - sa * sb) / den
            guard s.isFinite, s > 0.5, s < 2 else { continue }
            scale[axis] = s
            offset[axis] = (sb - s * sa) / n
        }
        return (scale, offset)
    }

    // MARK: 부착 헬퍼

    static func firstModelEntity(in prim: Entity) -> Entity? {
        if prim.components[ModelComponent.self] != nil { return prim }
        var found: Entity?
        prim.forEachDescendant { e in if found == nil, e.components[ModelComponent.self] != nil { found = e } }
        return found
    }

    /// `Library_<prim>`(InspectionView 가 library/<prim>.usdz 를 붙인 루트) 아래 첫 모델 엔티티 — 스킨 메시가 아마추어에 합쳐진 경우.
    static func libraryModelEntity(for prim: String, in root: Entity) -> Entity? {
        guard let lib = root.findEntity(named: "Library_\(prim)") else { return nil }
        return firstModelEntity(in: lib)
    }

    static func triangleCount(of entity: Entity) -> Int {
        guard let mc = entity.components[ModelComponent.self] else { return 0 }
        return mc.mesh.contents.models.reduce(0) { $0 + $1.parts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) / 3 } }
    }

    /// `e`(루트 기준 누적 변환 `matrix`)를 `restCenter` 가 피벗 원점에 오도록 옮겨 `pivot` 아래에 둔다.
    static func reparent(_ e: Entity, under pivot: Entity, matrix: simd_float4x4, restCenter: SIMD3<Float>) {
        var back = matrix_identity_float4x4
        back.columns.3 = SIMD4(-restCenter.x, -restCenter.y, -restCenter.z, 1)
        e.removeFromParent()
        pivot.addChild(e)
        e.transform = Transform(matrix: back * matrix)
    }

    /// 에셋 메시를 `LowLevelMesh`(position·normal·uv0·**uv1**) 로 다시 만든다 — uv1 = (presence × 헤어라인 페이드, height01).
    ///
    /// 왜 LowLevelMesh 인가(2026-10-08 실측): `MeshResource.Part.textureCoordinates1` 에 써서 `MeshResource.generate` 로 다시 만들면
    /// `mesh.contents` 에는 값이 들어 있는데 **셰이더 `geo.uv1()` 에는 닿지 않았다** — 셔츠 uv1.x 를 전부 0 으로 구워도 셔츠가
    /// 그대로 그려졌고, 렌더에 쓰인 건 USD 에서 온(블렌더가 구운) uv1 이었다. 그래서 "턴테이블에선 presence 끔"·셔츠 하단 페이드
    /// 끄기·헤어라인 페이드가 전부 조용히 무시되고, 유령 룩을 꺼도 셔츠가 블렌더 presence 의 z 페이드(0.06→0.20 m)로 아래가
    /// 투명했다. `LowLevelMesh` 의 `.uv1` 시맨틱은 "셰이더가 읽을 수 있는 범용 데이터"로 문서화돼 있어 이 경로를 쓴다.
    ///
    /// `splitRanges`(첫 파트의 삼각형 번호, 블렌더 faceRanges) 가 있으면 그 삼각형들을 `splitMaterialIndex` 파트로 떼어낸다(두피 캡).
    /// 스키닝·블렌드셰이프는 잃는다 — 헤어·셔츠(강체 근사, "스키닝은 M5")에만 쓰고 눈·입안은 건드리지 않는다.
    @discardableResult
    static func bakePresenceUV1(into entity: Entity, meshToBust: simd_float4x4, params: PresenceParams, headJoint: SIMD3<Float>, presence: Bool = true,
                                edgeFadeRanges: [Range<Int>] = [], edgeFadeWidth: Float = 0,
                                splitRanges: [Range<Int>] = [], splitMaterialIndex: Int = 1) -> Bool {
        guard var mc = entity.components[ModelComponent.self], let model = mc.mesh.contents.models.first else { return false }
        // 1) 파트들을 하나의 정점 배열로 모은다(파트마다 정점 버퍼가 따로라 오프셋을 더한다).
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv0: [SIMD2<Float>] = []
        var triLists: [(indices: [UInt32], materialIndex: Int)] = []
        var missingNormals = false
        for part in model.parts {
            let base = UInt32(positions.count)
            let p = part.positions.elements
            positions.append(contentsOf: p)
            if let n = part.normals?.elements, n.count == p.count { normals.append(contentsOf: n) } else { normals.append(contentsOf: [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: p.count)); missingNormals = true }
            if let t = part.textureCoordinates?.elements, t.count == p.count { uv0.append(contentsOf: t) } else { uv0.append(contentsOf: [SIMD2<Float>](repeating: .zero, count: p.count)) }
            let tri = (part.triangleIndices?.elements ?? []).map { $0 + base }
            triLists.append((tri, part.materialIndex))
        }
        guard !positions.isEmpty, !triLists.isEmpty else { return false }
        if missingNormals {
            let all = triLists.flatMap(\.indices)
            normals = Geometry.vertexNormals(positions: positions, indices: all)
        }
        // 2) uv1 — bust 공간에서 presence·height01, 첫 파트 기준 헤어라인 페이드.
        let bustPositions = positions.map { Geometry.transformPoint(meshToBust, $0) }
        var uv1 = bustPositions.map { q -> SIMD2<Float> in SIMD2(presence ? params.presence(at: q, headJoint: headJoint) : 1, params.height01(at: q)) }
        if edgeFadeWidth > 0, !edgeFadeRanges.isEmpty {
            let fades = edgeFade(positions: bustPositions, triangles: triLists[0].indices, ranges: edgeFadeRanges, width: edgeFadeWidth,
                                 headCenter: params.headCenter(headJoint: headJoint))
            for (v, f) in fades { uv1[v].x *= f }
        }
        // 3) 첫 파트에서 두피 캡 분리.
        if !splitRanges.isEmpty {
            let tri = triLists[0].indices, triCount = tri.count / 3
            var inRange = [Bool](repeating: false, count: triCount)
            for r in splitRanges { for t in r where t >= 0 && t < triCount { inRange[t] = true } }
            var rest = [UInt32](), picked = [UInt32]()
            rest.reserveCapacity(tri.count); picked.reserveCapacity(tri.count)
            for t in 0..<triCount { let s = t * 3; if inRange[t] { picked.append(contentsOf: tri[s..<s + 3]) } else { rest.append(contentsOf: tri[s..<s + 3]) } }
            if !picked.isEmpty, !rest.isEmpty {
                triLists[0].indices = rest
                triLists.insert((picked, splitMaterialIndex), at: 1)
            }
        }
        // 4) LowLevelMesh.
        let indices = triLists.flatMap(\.indices)
        var desc = LowLevelMesh.Descriptor()
        desc.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 1, offset: 0),
            .init(semantic: .uv0, format: .float2, layoutIndex: 2, offset: 0),
            .init(semantic: .uv1, format: .float2, layoutIndex: 3, offset: 0),
        ]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: 12), .init(bufferIndex: 1, bufferStride: 12), .init(bufferIndex: 2, bufferStride: 8), .init(bufferIndex: 3, bufferStride: 8)]
        desc.vertexCapacity = positions.count
        desc.indexCapacity = indices.count
        desc.indexType = .uint32
        guard let llm = try? LowLevelMesh(descriptor: desc) else { return false }
        BustEntity.fill(llm, bufferIndex: 0, with: positions)
        BustEntity.fill(llm, bufferIndex: 1, with: normals)
        llm.withUnsafeMutableBytes(bufferIndex: 2) { raw in let p = raw.bindMemory(to: SIMD2<Float>.self); for (i, v) in uv0.enumerated() { p[i] = v } }
        llm.withUnsafeMutableBytes(bufferIndex: 3) { raw in let p = raw.bindMemory(to: SIMD2<Float>.self); for (i, v) in uv1.enumerated() { p[i] = v } }
        llm.withUnsafeMutableIndices { raw in let p = raw.bindMemory(to: UInt32.self); for (i, v) in indices.enumerated() { p[i] = v } }
        var parts: [LowLevelMesh.Part] = []
        var offset = 0
        for list in triLists where !list.indices.isEmpty {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for v in list.indices { lo = simd_min(lo, positions[Int(v)]); hi = simd_max(hi, positions[Int(v)]) }
            parts.append(LowLevelMesh.Part(indexOffset: offset * MemoryLayout<UInt32>.size, indexCount: list.indices.count, topology: .triangle,
                                           materialIndex: list.materialIndex, bounds: BoundingBox(min: lo, max: hi)))
            offset += list.indices.count
        }
        llm.parts.replaceAll(parts)
        guard let mesh = try? MeshResource(from: llm) else { return false }
        mc.mesh = mesh
        let needed = (parts.map(\.materialIndex).max() ?? 0) + 1
        while mc.materials.count < needed { mc.materials.append(mc.materials.last ?? SimpleMaterial()) }
        entity.components.set(mc)
        return true
    }

    /// 헤어라인 페이드 계수: `ranges` 의 삼각형들이 이루는 조각(두피 캡)의 **테두리**(한 삼각형에만 속한 변) 중 앞·옆쪽
    /// (머리 중심 기준 뒤쪽 90° 는 제외 — 목덜미에서 긴 머리 뿌리가 비치지 않게)에서 `width` 안에 있는 **모든** 정점(캡뿐
    /// 아니라 거기서 자라는 카드 뿌리까지)에 0(테두리)…1(`width`) 계수를 준다. 범위 밖 정점은 돌려주지 않는다(계수 1).
    static func edgeFade(positions: [SIMD3<Float>], triangles tri: [UInt32], ranges: [Range<Int>], width: Float, headCenter: SIMD3<Float>) -> [(Int, Float)] {
        let triCount = tri.count / 3
        var edgeCount: [UInt64: Int] = [:]
        func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
        for r in ranges { for t in r where t >= 0 && t < triCount {
            let a = Int(tri[t * 3]), b = Int(tri[t * 3 + 1]), c = Int(tri[t * 3 + 2])
            edgeCount[key(a, b), default: 0] += 1; edgeCount[key(b, c), default: 0] += 1; edgeCount[key(c, a), default: 0] += 1
        } }
        let boundary: [(SIMD3<Float>, SIMD3<Float>)] = edgeCount.compactMap { k, n in
            guard n == 1 else { return nil }
            let a = Int(k >> 32), b = Int(k & 0xffff_ffff)
            guard a < positions.count, b < positions.count else { return nil }
            let mid = (positions[a] + positions[b]) * 0.5
            let d = SIMD2<Float>(mid.x - headCenter.x, mid.z - headCenter.z)
            let n2 = simd_length(d)
            let facing: Float = n2 > 1e-6 ? d.y / n2 : 1    // +Z(정면) 1 … 뒤 −1
            return facing > -0.2 ? (positions[a], positions[b]) : nil
        }
        guard !boundary.isEmpty else { return [] }
        // 테두리 경계상자 + width 밖은 거를 수 있다(카드 2.5만 정점 × 테두리 변 수백).
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for (a, b) in boundary { lo = simd_min(lo, simd_min(a, b)); hi = simd_max(hi, simd_max(a, b)) }
        lo -= SIMD3(repeating: width); hi += SIMD3(repeating: width)
        func distanceToSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let ab = b - a, l2 = simd_length_squared(ab)
            let t = l2 > 1e-12 ? min(1, max(0, simd_dot(p - a, ab) / l2)) : 0
            return simd_length(p - (a + ab * t))
        }
        var out: [(Int, Float)] = []
        for (v, p) in positions.enumerated() {
            guard all(p .>= lo) && all(p .<= hi) else { continue }
            var d = Float.greatestFiniteMagnitude
            for (a, b) in boundary { d = min(d, distanceToSegment(p, a, b)); if d <= 0 { break } }
            guard d < width else { continue }
            out.append((v, PresenceParams.smoothstep(0, width, d)))
        }
        return out
    }

    // MARK: 머티리얼 (역할별, 앱이 색·불투명도를 정한다)

    static func applyMaterials(to entity: Entity, entry: AssetEntry, look: PersonaLook, textures: PersonaTextureCache, shader: PersonaSurfaceShader?) async {
        guard var mc = entity.components[ModelComponent.self] else { return }
        mc.materials = await materials(for: entity, entry: entry, look: look, textures: textures, shader: shader)
        entity.components.set(mc)
    }

    /// 엔티티의 슬롯 수만큼 역할별 머티리얼을 만든다(적용은 호출자가).
    static func materials(for entity: Entity, entry: AssetEntry, look: PersonaLook, textures: PersonaTextureCache, shader: PersonaSurfaceShader?) async -> [Material] {
        guard let mc = entity.components[ModelComponent.self] else { return [] }
        var out: [Material] = []
        for i in mc.materials.indices {
            // 헤어의 추가 파트(bakePresenceUV1 이 뗀 두피 캡)는 슬롯 밖 인덱스 → 전용 역할.
            let role = (entry.kind == .hair && i >= 1) ? "hair_cap" : entry.role(forSlot: i)
            out.append(await material(role: role, entry: entry, look: look, textures: textures, shader: shader))
        }
        if out.isEmpty { out = [await material(role: entry.role(forSlot: 0), entry: entry, look: look, textures: textures, shader: shader)] }
        return out
    }

    /// 유령 룩 on/off 에 맞춰 셔츠 하단 페이드를 켜고 끈다 — 유령 룩이 꺼진(흉상이 불투명한) 상태에서 셔츠만 아래로 투명해지면
    /// 그 아래 피부색 몸통이 비쳐 "셔츠 아래가 맨살" 로 보였다(시뮬레이터 검수 2026-10-08). `setGhostLook` 이 부른다.
    func applyClothFade(ghost on: Bool) {
        for swap in clothFadeSwap {
            guard var mc = swap.entity.components[ModelComponent.self] else { continue }
            mc.materials = on ? swap.faded : swap.solid
            swap.entity.components.set(mc)
        }
    }

    static func material(role: String, entry: AssetEntry, look: PersonaLook, textures: PersonaTextureCache, shader: PersonaSurfaceShader?) async -> Material {
        func color(_ c: SIMD3<Float>) -> PhysicallyBasedMaterial.Color {
            .init(red: CGFloat(min(max(c.x, 0), 1)), green: CGFloat(min(max(c.y, 0), 1)), blue: CGFloat(min(max(c.z, 0), 1)), alpha: 1)
        }
        var pbr = PhysicallyBasedMaterial()
        pbr.metallic = .init(floatLiteral: 0)
        pbr.faceCulling = .back
        switch role {
        case "hair":
            let tint = look.hairTint / max(0.05, look.hairTextureMeanGray)
            let base = await textures.texture(named: entry.textures?["base"], semantic: .color)
            pbr.baseColor = .init(tint: color(tint), texture: base.map { .init($0) })
            pbr.roughness = .init(floatLiteral: 0.55)
            pbr.faceCulling = .none
            let fallbackWhite = base == nil ? await textures.white() : nil
            if let shader, let tex = base ?? fallbackWhite {
                pbr.baseColor = .init(tint: color(tint), texture: .init(tex))
                if let cm = shader.makeMaterial(from: pbr, fresnel: look.fresnelStrength, fade: .zero, baseOpacity: look.baseOpacity, opacityThreshold: look.hairOpacityThreshold) { return cm }
            }
            // PBR 폴백: 실루엣 = base 알파 → 불투명도 텍스처(R 채널), threshold 로 마스크
            if let alpha = await textures.alphaMask(named: entry.textures?["base"]) {
                pbr.blending = .transparent(opacity: .init(texture: .init(alpha)))
                pbr.opacityThreshold = look.hairOpacityThreshold
            }
            return pbr
        case "hair_cap":
            // 두피 캡: 카드와 같은 텍스처·틴트에 0.78 배(뿌리 그늘). 0.55 는 정수리에 검은 얼룩으로 보였다(실측 2026-10-08).
            let tint = look.hairTint / max(0.05, look.hairTextureMeanGray) * 0.78
            let base = await textures.texture(named: entry.textures?["base"], semantic: .color)
            pbr.baseColor = .init(tint: color(tint), texture: base.map { .init($0) })
            pbr.roughness = .init(floatLiteral: 0.7)
            let capWhite = base == nil ? await textures.white() : nil
            if let shader, let tex = base ?? capWhite {
                pbr.baseColor = .init(tint: color(tint), texture: .init(tex))
                // 프레넬 0: 정면 카메라에서 정수리 캡은 거의 스치는 각이라 프레넬 가장자리 소멸이 캡 전체를 반투명하게 만들어
                // 검은 무대가 비쳐 가르마 자리에 어두운 네모 판으로 보였다(시뮬레이터 검수 2026-10-08). 두피는 불투명해야 맞다.
                if let cm = shader.makeMaterial(from: pbr, fresnel: 0, fade: .zero, baseOpacity: look.baseOpacity, opacityThreshold: nil) { return cm }
            }
            return pbr
        case "cloth":
            pbr.baseColor = .init(tint: color(look.clothColor))
            pbr.roughness = .init(floatLiteral: 0.82)
            if let shader, let white = await textures.white() {
                pbr.baseColor = .init(tint: color(look.clothColor), texture: .init(white))
                if let cm = shader.makeMaterial(from: pbr, fresnel: look.fresnelStrength, fade: look.shirtFadeHeight01, baseOpacity: look.baseOpacity, opacityThreshold: nil) { return cm }
            }
            return pbr
        case "buttons":
            pbr.baseColor = .init(tint: color(SIMD3(0.85, 0.83, 0.78)))
            pbr.roughness = .init(floatLiteral: 0.45)
            return pbr
        case "sclera":
            let tex = await textures.texture(named: entry.textures?["sclera"], semantic: .color)
            pbr.baseColor = .init(tint: color(SIMD3(0.97, 0.96, 0.95)), texture: tex.map { .init($0) })
            pbr.roughness = .init(floatLiteral: 0.18)
            return pbr
        case "iris":
            let tex = await textures.texture(named: entry.textures?["iris"], semantic: .color)
            let tint = look.irisColor.map { $0 / 0.5 } ?? SIMD3(1, 1, 1)   // 텍스처 평균 밝기 ≈0.5 기준 틴트
            pbr.baseColor = .init(tint: color(tint), texture: tex.map { .init($0) })
            pbr.roughness = .init(floatLiteral: 0.25)
            pbr.clearcoat = .init(floatLiteral: 0.6)
            return pbr
        case "pupil":
            pbr.baseColor = .init(tint: color(SIMD3(0.02, 0.02, 0.02)))
            pbr.roughness = .init(floatLiteral: 0.10)
            return pbr
        case "teeth":
            let tex = await textures.texture(named: entry.textures?["teeth"], semantic: .color)
            pbr.baseColor = .init(tint: color(SIMD3(0.96, 0.94, 0.90)), texture: tex.map { .init($0) })
            pbr.roughness = .init(floatLiteral: 0.35)
            return pbr
        case "gum":
            pbr.baseColor = .init(tint: color(SIMD3(0.72, 0.36, 0.38)))
            pbr.roughness = .init(floatLiteral: 0.55)
            return pbr
        case "tongue":
            pbr.baseColor = .init(tint: color(SIMD3(0.70, 0.30, 0.33)))
            pbr.roughness = .init(floatLiteral: 0.6)
            return pbr
        case "cavity":
            pbr.baseColor = .init(tint: color(SIMD3(0.12, 0.04, 0.05)))
            pbr.roughness = .init(floatLiteral: 0.9)
            return pbr
        default:
            // 블렌더 틀 머티리얼(무채색 10%)은 그대로 두면 거의 안 보인다 → 불투명 중간 회색으로.
            pbr.baseColor = .init(tint: color(SIMD3(0.6, 0.6, 0.6)))
            pbr.roughness = .init(floatLiteral: 0.7)
            return pbr
        }
    }
}

/// Template/textures/ 의 PNG 를 `TextureResource` 로(파일마다 1회). 헤어 실루엣용 알파 마스크(R=G=B=알파)도 만든다.
public final class PersonaTextureCache {
    public let folder: URL
    private var cache: [String: TextureResource] = [:]
    private var whiteTexture: TextureResource?
    public init(folder: URL) { self.folder = folder }

    @MainActor
    public func texture(named name: String?, semantic: TextureResource.Semantic) async -> TextureResource? {
        guard let name, !name.isEmpty else { return nil }
        let key = "\(semantic)|\(name)"
        if let t = cache[key] { return t }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let t = try? await TextureResource(contentsOf: url, options: .init(semantic: semantic)) else { return nil }
        cache[key] = t
        return t
    }

    /// base PNG 의 알파 채널 → 그레이 이미지(R 채널이 불투명도) — `PhysicallyBasedMaterial.Opacity(texture:)` 는 R 만 본다.
    @MainActor
    public func alphaMask(named name: String?) async -> TextureResource? {
        guard let name, !name.isEmpty else { return nil }
        let key = "alpha|\(name)"
        if let t = cache[key] { return t }
        let url = folder.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        guard let alphaCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        alphaCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = alphaCtx.data else { return nil }
        guard let grayCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let dst = grayCtx.data else { return nil }
        memcpy(dst, data, w * h)
        guard let gray = grayCtx.makeImage(), let t = try? await TextureResource(image: gray, withName: "coursona-alpha-\(name)", options: .init(semantic: .raw)) else { return nil }
        cache[key] = t
        return t
    }

    /// 1×1 흰색 — 셰이더가 `base_color` 텍스처를 항상 샘플하므로 텍스처 없는 역할(셔츠)에 넣는다.
    @MainActor
    public func white() async -> TextureResource? {
        if let whiteTexture { return whiteTexture }
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let cg = ctx.makeImage(), let t = try? await TextureResource(image: cg, withName: "coursona-white", options: .init(semantic: .color)) else { return nil }
        whiteTexture = t
        return t
    }
}
