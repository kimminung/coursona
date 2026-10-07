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
        let shader = (look.useGhostShader && Self.canBakeUV1) ? PersonaSurfaceShader.shared : nil
        report.shader = shader != nil
        if look.useGhostShader && !Self.canBakeUV1 { report.notes.append("OS 26: uv1 쓰기 불가 → PBR 폴백") }
        let textures = PersonaTextureCache(folder: texturesFolder)
        let m = template.manifest
        let restEyeL = SIMD3<Float>(m.eyeL[0], m.eyeL[1], m.eyeL[2]), restEyeR = SIMD3<Float>(m.eyeR[0], m.eyeR[1], m.eyeR[2])
        let eyeScale = max(0.5, min(2.0, identity.eyeRadius / max(1e-4, m.eyeRadius)))
        var eyesAttached = false, mouthAttached = false

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
            guard let modelEntity else { item.note = "ModelComponent 없음"; continue }
            item.triangles = Self.triangleCount(of: modelEntity)
            if let exp = entry.triangleCount, exp > 0, exp != item.triangles { item.note = "삼각형 수 불일치(매니페스트 \(exp))" }

            // 흉상 공간 변환(USD 스테이지·아마추어 변환 포함) — root 는 아직 부모가 없으므로 nil 기준 = root 포함.
            let toBust = prim.transformMatrix(relativeTo: nil)
            let meshToBust = modelEntity.transformMatrix(relativeTo: nil)
            Self.bakePresenceUV1(into: modelEntity, meshToBust: meshToBust, params: manifest.presence, headJoint: headJointRest, presence: look.presenceEnabled)
            // 헤어: 두피 캡(faceRanges.cap)을 별도 파트로 떼어 어둡게 — 캡 칸 텍스처가 카드보다 밝아 정수리에 회색 판이 비쳤다(실측 2026-10-08).
            if entry.kind == .hair, let cap = entry.faceRanges?["cap"], !cap.ranges.isEmpty {
                Self.splitTriangleRanges(of: modelEntity, ranges: cap.ranges, materialIndex: 1)
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
                Self.reparent(prim, under: model, matrix: toBust, restCenter: .zero)
            }
            await Self.applyMaterials(to: modelEntity, entry: entry, look: look, textures: textures, shader: shader)
            item.attached = true
        }

        if eyesAttached || mouthAttached {
            hasEyesMouth = true
            setCapsHidden(eyes: eyesAttached, mouth: mouthAttached)
            updateMouthInner(lastWeights)
        }
        return report
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

    /// 첫 파트에서 삼각형 구간(`faceRanges`, 블렌더 삼각형 번호 — USD 가져오기가 면 순서를 보존한다는 전제)을 떼어
    /// `materialIndex` 파트로 만든다. 한 머티리얼 슬롯으로 나온 에셋의 일부(두피 캡)를 다른 머티리얼로 그리기 위해.
    static func splitTriangleRanges(of entity: Entity, ranges: [Range<Int>], materialIndex: Int) {
        guard var mc = entity.components[ModelComponent.self], !ranges.isEmpty else { return }
        var contents = mc.mesh.contents
        var models = [MeshResource.Model](), did = false
        for model in contents.models {
            var parts = [MeshResource.Part]()
            for part in model.parts {
                guard !did, let tri = part.triangleIndices?.elements else { parts.append(part); continue }
                let triCount = tri.count / 3
                var inRange = [Bool](repeating: false, count: triCount)
                for r in ranges { for t in r where t >= 0 && t < triCount { inRange[t] = true } }
                var rest = [UInt32](), picked = [UInt32]()
                rest.reserveCapacity(tri.count); picked.reserveCapacity(tri.count)
                for t in 0..<triCount {
                    let s = t * 3
                    if inRange[t] { picked.append(contentsOf: tri[s..<s + 3]) } else { rest.append(contentsOf: tri[s..<s + 3]) }
                }
                guard !picked.isEmpty, !rest.isEmpty else { parts.append(part); continue }
                var a = part; a.triangleIndices = MeshBuffer(rest)
                var b = part; b.id = part.id + "_range\(materialIndex)"; b.triangleIndices = MeshBuffer(picked); b.materialIndex = materialIndex
                parts.append(a); parts.append(b); did = true
            }
            var m = model; m.parts = MeshPartCollection(parts); models.append(m)
        }
        guard did else { return }
        contents.models = MeshModelCollection(models)
        guard let mesh = try? MeshResource.generate(from: contents) else { return }
        mc.mesh = mesh
        while mc.materials.count <= materialIndex { mc.materials.append(mc.materials.last ?? SimpleMaterial()) }
        entity.components.set(mc)
    }

    /// `MeshResource.Part.textureCoordinates1`(uv1 쓰기)은 OS 27+ — 그 아래에선 presence 셰이더를 못 쓰고 PBR 폴백.
    static var canBakeUV1: Bool {
        if #available(macOS 27, iOS 27, *) { return true }
        return false
    }

    /// uv1 = (presence, height01) 을 bust 공간 정점으로 굽는다(AssetContract §5 식 — `PresenceParams`).
    static func bakePresenceUV1(into entity: Entity, meshToBust: simd_float4x4, params: PresenceParams, headJoint: SIMD3<Float>, presence: Bool = true) {
        guard #available(macOS 27, iOS 27, *) else { return }
        guard var mc = entity.components[ModelComponent.self] else { return }
        var contents = mc.mesh.contents
        var changed = false
        var models = [MeshResource.Model]()
        for model in contents.models {
            var parts = [MeshResource.Part]()
            for var part in model.parts {
                let uv1 = part.positions.elements.map { p -> SIMD2<Float> in
                    let q = Geometry.transformPoint(meshToBust, p)
                    return SIMD2(presence ? params.presence(at: q, headJoint: headJoint) : 1, params.height01(at: q))
                }
                part.textureCoordinates1 = MeshBuffer(uv1)
                parts.append(part); changed = true
            }
            var m = model
            m.parts = MeshPartCollection(parts)
            models.append(m)
        }
        guard changed else { return }
        contents.models = MeshModelCollection(models)
        if let mesh = try? MeshResource.generate(from: contents) {
            mc.mesh = mesh
            entity.components.set(mc)
        }
    }

    // MARK: 머티리얼 (역할별, 앱이 색·불투명도를 정한다)

    static func applyMaterials(to entity: Entity, entry: AssetEntry, look: PersonaLook, textures: PersonaTextureCache, shader: PersonaSurfaceShader?) async {
        guard var mc = entity.components[ModelComponent.self] else { return }
        var out: [Material] = []
        for i in mc.materials.indices {
            // 헤어의 추가 파트(splitTriangleRanges 로 뗀 두피 캡)는 슬롯 밖 인덱스 → 전용 역할.
            let role = (entry.kind == .hair && i >= 1) ? "hair_cap" : entry.role(forSlot: i)
            out.append(await material(role: role, entry: entry, look: look, textures: textures, shader: shader))
        }
        if out.isEmpty { out = [await material(role: entry.role(forSlot: 0), entry: entry, look: look, textures: textures, shader: shader)] }
        mc.materials = out
        entity.components.set(mc)
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
                if let cm = shader.makeMaterial(from: pbr, fresnel: look.fresnelStrength, fade: .zero, baseOpacity: look.baseOpacity, opacityThreshold: nil) { return cm }
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
