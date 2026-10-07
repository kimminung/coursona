//
//  AssetManifest.swift
//  CoursonaCore
//
//  `Template/coursona_assets.json` — Persona 재현 에셋(Hair · Shoulders · Eye_L/R · Mouth_Inner)의 테크 매니페스트.
//  정본은 `Docs/AssetContract.md` §4 와 블렌더 `coursona_blender/coursona_common.py` 의 `MANIFEST`(이 파일을 쓰는 쪽).
//  키는 블렌더 스크립트가 **실제로 쓰는 그대로** 받는다: presence 는 snake_case, `attach` 는 kind 마다 다르고(강체
//  `bone` / 스킨 `joints`), `faceRanges` 값은 `[a, b]` 또는 `[[a, b], …]`(같은 라벨이 끊겨 있을 때), `splatHost` 는
//  문자열 또는 null, `textures` 는 없을 수 있다(셔츠). 알 수 없는 키·설명 문자열은 무시한다.
//

import Foundation
import simd

public struct CoursonaAssetManifest: Codable, Sendable, Equatable {
    public static let supportedSchema = "coursona-assets/1"

    public var schema: String
    public var presence: PresenceParams = PresenceParams()
    public var bust: BustInfo? = nil
    public var assets: [String: AssetEntry] = [:]

    public var isSupported: Bool { schema == Self.supportedSchema }

    /// 종류별 에셋(프림 이름 순 — 눈은 Eye_L, Eye_R 순서가 된다).
    public func assets(ofKind kind: AssetEntry.Kind) -> [AssetEntry] {
        assets.values.filter { $0.kind == kind }.sorted { $0.prim < $1.prim }
    }

    public init(schema: String = CoursonaAssetManifest.supportedSchema, presence: PresenceParams = PresenceParams(), assets: [String: AssetEntry] = [:]) {
        self.schema = schema; self.presence = presence; self.assets = assets
    }

    enum CodingKeys: String, CodingKey { case schema, presence, bust, assets }

    public struct BustInfo: Codable, Sendable, Equatable {
        public var prim: String? = nil
        /// 블렌더가 Bust 피부 머티리얼에 준 기본 불투명도(틀 값) — 앱은 참고만 하고 자기 값을 쓴다.
        public var opacity: Float? = nil
        enum CodingKeys: String, CodingKey { case prim, opacity }
        public init(prim: String? = nil, opacity: Float? = nil) { self.prim = prim; self.opacity = opacity }
    }
}

/// presence(정적 존재 마스크) 파라미터 — AssetContract §5. 블렌더는 uv1.x 에 굽고, 앱은 같은 식으로 다시 계산할 수 있다.
public struct PresenceParams: Codable, Sendable, Equatable {
    public var version: String? = "presence/v1"
    public var facingLo: Float = -0.30
    public var facingHi: Float = 0.35
    public var zLo: Float = 0.06
    public var zHi: Float = 0.20
    public var heightScale: Float = 0.60

    enum CodingKeys: String, CodingKey {
        case version
        case facingLo = "facing_lo", facingHi = "facing_hi", zLo = "z_lo", zHi = "z_hi", heightScale = "height_scale"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        facingLo = try c.decodeIfPresent(Float.self, forKey: .facingLo) ?? facingLo
        facingHi = try c.decodeIfPresent(Float.self, forKey: .facingHi) ?? facingHi
        zLo = try c.decodeIfPresent(Float.self, forKey: .zLo) ?? zLo
        zHi = try c.decodeIfPresent(Float.self, forKey: .zHi) ?? zHi
        heightScale = try c.decodeIfPresent(Float.self, forKey: .heightScale) ?? heightScale
    }

    /// 머리 중심(블렌더 `head_c` = Head 뼈 머리 + 0.09 위, USD 로는 +Y).
    public func headCenter(headJoint: SIMD3<Float>) -> SIMD3<Float> { headJoint + SIMD3(0, 0.09, 0) }

    /// 흉상(USD) 공간 점의 presence: 정면 1 → 옆 ≈0.44 → 뒤 0, 가슴 아래(y < zLo)로 0.
    /// 블렌더 식 `dot(normalize(p.xy − c.xy), (0, −1))` 은 USD 에서 `dot(normalize((p.x, p.z) − (c.x, c.z)), (0, +1))`,
    /// 높이 `z_blender` 는 USD `y`.
    public func presence(at p: SIMD3<Float>, headJoint: SIMD3<Float>) -> Float {
        let c = headCenter(headJoint: headJoint)
        let d = SIMD2<Float>(p.x - c.x, p.z - c.z)
        let n = simd_length(d)
        let facing: Float = n > 1e-6 ? d.y / n : 1
        return Self.smoothstep(facingLo, facingHi, facing) * Self.smoothstep(zLo, zHi, p.y)
    }

    public func height01(at p: SIMD3<Float>) -> Float { min(max(p.y / heightScale, 0), 1) }

    public static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        guard e1 != e0 else { return x >= e1 ? 1 : 0 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 에셋 한 개(`assets` 의 값). 프림 이름으로 Template.usdz 에서 찾는다.
public struct AssetEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case hair, shoulders, eye, mouth, glasses, beard, other
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    public struct Attach: Codable, Sendable, Equatable {
        /// "rigid"(Head·Eye_L·Eye_R 에 강체) / "skin"(Root·Neck 스킨)
        public var mode: String
        public var bone: String? = nil
        public var joints: [String]? = nil
        public var blender: String? = nil
        public var pivot: String? = nil
        public var isRigid: Bool { mode == "rigid" }
        enum CodingKeys: String, CodingKey { case mode, bone, joints, blender, pivot }
        public init(mode: String, bone: String? = nil, joints: [String]? = nil) { self.mode = mode; self.bone = bone; self.joints = joints }
    }

    public struct MaterialSlot: Codable, Sendable, Equatable {
        public var name: String
        /// hair · cloth · buttons · sclera · iris · pupil · teeth · gum · tongue · cavity (없으면 머티리얼 이름)
        public var role: String
        public init(name: String, role: String) { self.name = name; self.role = role }
    }

    public struct MaterialSpec: Codable, Sendable, Equatable {
        public var opacity: Float? = nil
        public var colorless: Bool? = nil
        public var slots: [MaterialSlot] = []
        enum CodingKeys: String, CodingKey { case opacity, colorless, slots }
        public init(opacity: Float? = nil, colorless: Bool? = nil, slots: [MaterialSlot] = []) { self.opacity = opacity; self.colorless = colorless; self.slots = slots }
    }

    /// 면 구간(삼각형 번호, [시작, 끝)). 같은 라벨이 끊겨 있으면 구간이 여럿.
    public struct FaceRange: Codable, Sendable, Equatable {
        public var ranges: [Range<Int>]
        public init(_ ranges: [Range<Int>]) { self.ranges = ranges }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let flat = try? c.decode([Int].self) {
                ranges = flat.count == 2 && flat[0] <= flat[1] ? [flat[0]..<flat[1]] : []
            } else {
                let nested = try c.decode([[Int]].self)
                ranges = nested.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]..<$0[1] : nil }
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            if ranges.count == 1 { try c.encode([ranges[0].lowerBound, ranges[0].upperBound]) }
            else { try c.encode(ranges.map { [$0.lowerBound, $0.upperBound] }) }
        }
        public var triangleCount: Int { ranges.reduce(0) { $0 + $1.count } }
    }

    public var prim: String
    public var kind: Kind
    public var attach: Attach
    public var material: MaterialSpec = MaterialSpec()
    /// 역할 → 파일 이름(Template/textures/). hair: base·mask, eye: iris·sclera, mouth: teeth. 셔츠는 없다.
    public var textures: [String: String]? = nil
    public var silhouette: String? = nil
    public var blendShapes: [String]? = nil
    public var vertexCount: Int? = nil
    public var triangleCount: Int? = nil
    public var topologyHash: String? = nil
    public var faceRanges: [String: FaceRange]? = nil
    public var splatHost: String? = nil
    public var splatHostHash: String? = nil

    enum CodingKeys: String, CodingKey {
        case prim, kind, attach, material, textures, silhouette, blendShapes, vertexCount, triangleCount, topologyHash, faceRanges, splatHost, splatHostHash
    }

    public init(prim: String, kind: Kind, attach: Attach) { self.prim = prim; self.kind = kind; self.attach = attach }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prim = try c.decode(String.self, forKey: .prim)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        attach = try c.decodeIfPresent(Attach.self, forKey: .attach) ?? Attach(mode: "rigid", bone: "Head")
        material = try c.decodeIfPresent(MaterialSpec.self, forKey: .material) ?? MaterialSpec()
        textures = try c.decodeIfPresent([String: String].self, forKey: .textures)
        silhouette = try c.decodeIfPresent(String.self, forKey: .silhouette)
        blendShapes = try c.decodeIfPresent([String].self, forKey: .blendShapes)
        vertexCount = try c.decodeIfPresent(Int.self, forKey: .vertexCount)
        triangleCount = try c.decodeIfPresent(Int.self, forKey: .triangleCount)
        topologyHash = try c.decodeIfPresent(String.self, forKey: .topologyHash)
        faceRanges = try c.decodeIfPresent([String: FaceRange].self, forKey: .faceRanges)
        splatHost = try c.decodeIfPresent(String.self, forKey: .splatHost)
        splatHostHash = try c.decodeIfPresent(String.self, forKey: .splatHostHash)
    }

    /// 슬롯 순서대로의 역할. 매니페스트 슬롯이 모자라면 kind 의 기본 역할로 채운다.
    public func role(forSlot i: Int) -> String {
        if i < material.slots.count { return material.slots[i].role }
        switch kind {
        case .hair: return "hair"
        case .shoulders: return i == 0 ? "cloth" : "buttons"
        case .eye: return ["sclera", "iris", "pupil"][min(i, 2)]
        case .mouth: return ["teeth", "gum", "tongue", "cavity"][min(i, 3)]
        default: return "other"
        }
    }
}
