//
//  BustTemplate.swift
//  CoursonaCore
//
//  블렌더 흉상 템플릿의 **인메모리 표현**. 기하의 진실(TechPRD §2). `bust.mesh`(기본) 또는 USDZ(CoursonaRig 로더) + `template.json` 에서 만든다.
//  좌표계: m, Y-up, 얼굴 +Z, 피사체 왼쪽 +X. 정점 0…1219 는 Apple `ARFaceGeometry.obj` 순서 그대로의 얼굴 패치.
//  template.json 스키마 2 (2차 계약, Blender-요청.md §6): `export_coursona.py` 가 Bust 커스텀 속성 4개에서 만든다.
//

import Foundation
import simd

/// 계약상 버텍스 그룹 이름 (Blender-요청.md §1-3). `Neck` 은 영역이자 Neck 뼈 스킨 가중치(2차 계약 #2) — 영역 집합 = 가중치 > 0.
public enum VertexGroupName: String, CaseIterable, Codable, Sendable {
    case arkitFace = "ARKitFace"
    case scalp = "Scalp"
    case earL = "EarL"
    case earR = "EarR"
    case neck = "Neck"
    case shoulders = "Shoulders"
    case lipInner = "LipInner"
    case lidInner = "LidInner"
}

/// 계약상 랜드마크 이름 (template.json `landmarks`, 블렌더 `coursona_landmarks` 와 동일한 snake_case). Left = 피사체 왼쪽(+X).
public enum LandmarkName: String, CaseIterable, Codable, Sendable {
    case eyeLeftInner = "eye_left_inner", eyeLeftOuter = "eye_left_outer", eyeRightInner = "eye_right_inner", eyeRightOuter = "eye_right_outer"
    case noseTip = "nose_tip"
    case mouthLeft = "mouth_left", mouthRight = "mouth_right"
    case chin
    case earTopLeft = "ear_top_left", earTopRight = "ear_top_right"
    case shoulderLeft = "shoulder_left", shoulderRight = "shoulder_right"
    // 선택 (스크립트가 입 루프에서 유도; 없으면 경고만)
    case lipUpperMid = "lip_upper_mid", lipLowerMid = "lip_lower_mid"
    case browInnerLeft = "brow_inner_left", browInnerRight = "brow_inner_right"

    public static let required: [LandmarkName] = [.eyeLeftInner, .eyeLeftOuter, .eyeRightInner, .eyeRightOuter, .noseTip, .mouthLeft, .mouthRight, .chin,
                                                  .earTopLeft, .earTopRight, .shoulderLeft, .shoulderRight]
    public var isRequired: Bool { Self.required.contains(self) }
}

/// 계약상 뼈 이름 (Blender-요청.md §3).
public enum BoneName: String, CaseIterable, Codable, Sendable {
    case root = "Root", spine = "Spine", neck = "Neck", head = "Head", eyeL = "Eye_L", eyeR = "Eye_R"
}

/// 라이브러리 오브젝트 메타 (library.json 항목).
public struct LibraryEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case hair, glasses, beard, shoulders }
    public var name: String
    public var kind: Kind
    /// 스킨 뼈 (hair/glasses/beard = Head, shoulders = Root+Neck 가중치 복사)
    public var bone: String
    public var tintable: Bool
    public var vertexCount: Int
    public var faceCount: Int
    public var materials: [String] = []
    /// 텍스처 역할 → 파일 이름 (base / mask / cap)
    public var textures: [String: String] = [:]
    /// 수염: 셸 정점 → 원본 Bust 정점 (2차 계약 #5). 앱이 Bust 변형을 복사해 따라가게 한다.
    public var bustIndex: [Int]? = nil
    /// 안경: 코 받침 위치 (흉상 공간)
    public var noseBridge: [Float]? = nil
    /// 스킨 가중치 그룹 이름 (shoulders: Root·Neck)
    public var skinGroups: [String] = []
    public init(name: String, kind: Kind, bone: String, tintable: Bool, vertexCount: Int, faceCount: Int) {
        self.name = name; self.kind = kind; self.bone = bone; self.tintable = tintable; self.vertexCount = vertexCount; self.faceCount = faceCount
    }

    /// 선택 키(materials·textures·bustIndex·noseBridge·skinGroups)가 빠진 항목도 읽는다 — 블렌더 `coursona_blender` 의
    /// `update_library_json` 은 종류별로 있는 키만 쓴다(헤어: materials·textures, 셔츠: skinGroups). 합성 디코더는
    /// 기본값이 있어도 키가 없으면 실패하므로 직접 쓴다. `bone`·`tintable` 도 없으면 kind 기본값으로 채운다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        bone = try c.decodeIfPresent(String.self, forKey: .bone) ?? (kind == .shoulders ? "Root" : "Head")
        tintable = try c.decodeIfPresent(Bool.self, forKey: .tintable) ?? (kind == .hair)
        vertexCount = try c.decodeIfPresent(Int.self, forKey: .vertexCount) ?? 0
        faceCount = try c.decodeIfPresent(Int.self, forKey: .faceCount) ?? 0
        materials = try c.decodeIfPresent([String].self, forKey: .materials) ?? []
        textures = try c.decodeIfPresent([String: String].self, forKey: .textures) ?? [:]
        bustIndex = try c.decodeIfPresent([Int].self, forKey: .bustIndex)
        noseBridge = try c.decodeIfPresent([Float].self, forKey: .noseBridge)
        skinGroups = try c.decodeIfPresent([String].self, forKey: .skinGroups) ?? []
    }
}

/// 프리비즈 카메라 (2차 계약 #9): 맨 흉상, 조준점 (0, 0.41, 0.09), 카메라 (0, 0.41, 1.29), 수평 FOV 39.60°, 1920×1080, 30 fps.
public struct PrevizCameraSpec: Codable, Sendable, Equatable {
    public var aim: [Float] = [0, 0.41, 0.09]
    public var position: [Float] = [0, 0.41, 1.29]
    public var horizontalFOVDegrees: Float = 39.60
    public var width = 1920
    public var height = 1080
    public var fps: Float = 30
    public var bareBust = true
    public init() {}
    public static let contract = PrevizCameraSpec()
    /// 세로 FOV (RealityKit PerspectiveCamera 의 fieldOfViewInDegrees 는 세로 기준).
    public var verticalFOVDegrees: Float {
        let h = horizontalFOVDegrees * .pi / 180
        return 2 * atan(tan(h / 2) * Float(height) / Float(width)) * 180 / .pi
    }
}

/// template.json — 블렌더 내보내기 스크립트가 쓰고, 검증기·로더가 읽는다. 스키마 2.
public struct TemplateManifest: Codable, Sendable, Equatable {
    public var schema: Int = 2
    public var id: String
    public var version: String
    /// 내보낸 블렌더 버전 등 자유 메모
    public var generator: String = ""
    public var vertexCount: Int
    public var triangleCount: Int
    /// 패치 정점 수 (항상 1220) · 사각형 수 (1152)
    public var patchVertexCount: Int = ARKitFaceTopology.vertexCount
    public var patchFaceCount: Int = ARKitFaceTopology.quadCount
    /// 2차 계약 해시: Apple OBJ 파일, 패치 사각형(OBJ 순서), (a,b,c)+(a,c,d) 삼각형 — 모두 SHA-256 16진수
    public var objSHA256: String? = nil
    public var patchQuadsSHA256: String? = nil
    public var patchTrianglesSHA256: String? = nil
    /// 메시 패치 삼각형의 FNV-1a 64 (16진수) — 로더가 bust.mesh 와 비교
    public var patchTriangleHash: String
    /// OBJ(mm) → 템플릿(m): usd = obj × scale + translate
    public var objToTemplate: [String: [Float]]? = nil
    /// 랜드마크 이름 → 정점 id
    public var landmarks: [String: Int]
    /// 랜드마크 이름 → Vision 76 인덱스 (희소 폴백용)
    public var visionIndices: [String: Int] = [:]
    /// 버텍스 그룹 → 정점 id 목록 (Neck 은 가중치 > 0)
    public var groups: [String: [Int]]
    /// 가중치 그룹 (Neck·Root·Head 스킨) → 정점별 가중치 (groups 와 같은 순서)
    public var groupWeights: [String: [Float]] = [:]
    /// 패치 루프 (OBJ 경계): eye_left(24)·eye_right(24)·mouth(36)·outer(56)
    public var patchLoops: [String: [Int]] = [:]
    /// UV 영역 박스 [u0, v0, u1, v1]
    public var uvRegions: [String: [Float]] = [:]
    /// 좌우 대칭 정점 맵 (i → 거울 정점). 길이 = vertexCount, 없으면 -1
    public var symmetryMap: [Int32] = []
    /// 눈알 중심·반지름 (흉상 공간)
    public var eyeL: [Float] = [0.032, 0.44, 0.0722], eyeR: [Float] = [-0.032, 0.44, 0.0722], eyeRadius: Float = 0.012
    /// 측정값: 눈 간격, 입 중심, 턱끝 y, 정수리 y
    public var eyeSpacing: Float? = nil
    public var mouthCenter: [Float]? = nil
    public var chinY: Float? = nil
    public var crownY: Float? = nil
    /// 턱 리그 (jawOpen 의 회전 피벗·각도·이동, 흉상 공간) — Mouth_Inner·수염 동기화에 쓴다
    public var jawPivot: [Float]? = nil
    public var jawOpenDegrees: Float? = nil
    public var jawOpenTranslate: [Float]? = nil
    /// 뼈 레스트 포즈 (이름 → 월드 위치 xyz) · 부모
    public var boneRest: [String: [Float]] = [:]
    public var boneParents: [String: String] = [:]
    /// 셰이프키 이름 목록 (52) · 최대 변위(mm)
    public var shapeKeys: [String]
    public var shapeMaxDisplacementMM: [String: Float] = [:]
    /// Mouth_Inner 셰이프키 (jawOpen/jawLeft/jawRight/jawForward/tongueOut — Bust 와 같은 이름·값)
    public var mouthInnerShapes: [String] = []
    /// 라이브러리 오브젝트 이름 (library.json 에 상세)
    public var libraryObjects: [String] = []
    /// 클립 이름 목록
    public var clips: [String] = []
    public var previz: PrevizCameraSpec? = nil
    /// 동봉 텍스처 파일 이름
    public var textures: [String] = []
    /// UV 솔기 때문에 UV 가 둘 이상인 정점 수 (bust.mesh 는 정점당 UV 1개 — 로더가 알고 있어야 함)
    public var uvSeamVertexCount: Int? = nil

    public init(id: String, version: String, vertexCount: Int, triangleCount: Int, patchTriangleHash: String,
                landmarks: [String: Int], groups: [String: [Int]], shapeKeys: [String]) {
        self.id = id; self.version = version; self.vertexCount = vertexCount; self.triangleCount = triangleCount
        self.patchTriangleHash = patchTriangleHash; self.landmarks = landmarks; self.groups = groups; self.shapeKeys = shapeKeys
    }

    public func landmark(_ name: LandmarkName) -> Int? { landmarks[name.rawValue] }
    public func group(_ name: VertexGroupName) -> [Int] { groups[name.rawValue] ?? [] }
    public var eyeCenterL: SIMD3<Float> { SIMD3(eyeL[0], eyeL[1], eyeL[2]) }
    public var eyeCenterR: SIMD3<Float> { SIMD3(eyeR[0], eyeR[1], eyeR[2]) }
    public var isSynthetic: Bool { generator.hasPrefix("CoursonaCore.SyntheticTemplate") }
}

/// 정점당 스킨 영향 (조인트 4개).
public struct SkinInfluence: Sendable, Equatable {
    public var joints: SIMD4<UInt16>
    public var weights: SIMD4<Float>
    public init(joints: SIMD4<UInt16>, weights: SIMD4<Float>) { self.joints = joints; self.weights = weights }
    public static let none = SkinInfluence(joints: .zero, weights: SIMD4(1, 0, 0, 0))
}

/// 스켈레톤 (조인트 이름·부모·레스트 변환·역바인드).
public struct TemplateSkeleton: Sendable, Equatable {
    public var jointNames: [String]
    public var parentIndices: [Int]
    /// 모델 공간 레스트 변환 (조인트 → 모델)
    public var restWorld: [simd_float4x4]
    public var inverseBind: [simd_float4x4]
    public init(jointNames: [String], parentIndices: [Int], restWorld: [simd_float4x4]) {
        self.jointNames = jointNames; self.parentIndices = parentIndices; self.restWorld = restWorld
        self.inverseBind = restWorld.map { $0.inverse }
    }
    public func index(of bone: BoneName) -> Int? { jointNames.firstIndex { $0 == bone.rawValue || $0.hasSuffix("/" + bone.rawValue) } }
    public func restPosition(of bone: BoneName) -> SIMD3<Float>? {
        guard let i = index(of: bone) else { return nil }
        let c = restWorld[i].columns.3
        return SIMD3(c.x, c.y, c.z)
    }
}

/// 흉상 템플릿.
public struct BustTemplate: Sendable {
    public var manifest: TemplateManifest
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var uvs: [SIMD2<Float>]
    public var indices: [UInt32]
    /// 셰이프 → 정점 전체 길이 델타 (없는 셰이프는 키 없음)
    public var shapeDeltas: [ArkitShape: [SIMD3<Float>]]
    public var skin: [SkinInfluence]
    public var skeleton: TemplateSkeleton?
    /// 삼각형 코너별 UV (3 × T). 솔기에서 정점 UV 가 갈라지므로 렌더·텍스처는 이것을 쓴다(없으면 `uvs`).
    public var cornerUVs: [SIMD2<Float>]? = nil
    /// 로더가 만든 캐시 키 (id + version + 정점 수 + 패치 해시)
    public var cacheKey: String { "\(manifest.id)@\(manifest.version)#\(positions.count)#\(manifest.patchTriangleHash)" }

    public init(manifest: TemplateManifest, positions: [SIMD3<Float>], normals: [SIMD3<Float>]? = nil, uvs: [SIMD2<Float>], indices: [UInt32],
                shapeDeltas: [ArkitShape: [SIMD3<Float>]], skin: [SkinInfluence]? = nil, skeleton: TemplateSkeleton? = nil) {
        self.manifest = manifest
        self.positions = positions
        self.normals = normals ?? Geometry.vertexNormals(positions: positions, indices: indices)
        self.uvs = uvs
        self.indices = indices
        self.shapeDeltas = shapeDeltas
        self.skin = skin ?? [SkinInfluence](repeating: .none, count: positions.count)
        self.skeleton = skeleton
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var patchCount: Int { min(manifest.patchVertexCount, positions.count) }
    public var patchPositions: ArraySlice<SIMD3<Float>> { positions[0..<patchCount] }

    /// 눈 간격 (manifest eyeL/eyeR).
    public var eyeSpacing: Float { simd_length(manifest.eyeCenterL - manifest.eyeCenterR) }

    /// 패치 경계 정점(패치 삼각형과 비패치 삼각형이 공유하는 정점) — RBF 중심. manifest 에 outer 루프가 있으면 그것.
    public func patchBoundaryVertices() -> [Int] {
        if let outer = manifest.patchLoops["outer"], !outer.isEmpty { return outer }
        let pc = patchCount
        var boundary = Set<Int>()
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let inside = [a < pc, b < pc, c < pc]
            if inside.contains(true) && inside.contains(false) {
                if a < pc { boundary.insert(a) }
                if b < pc { boundary.insert(b) }
                if c < pc { boundary.insert(c) }
            }
            i += 3
        }
        return boundary.sorted()
    }

    /// 가중치를 적용한 정점 (CPU 참조 구현: 템플릿 + Σ w·Δ).
    public func deformedPositions(weights: ArkitWeights, base: [SIMD3<Float>]? = nil) -> [SIMD3<Float>] {
        var out = base ?? positions
        for (shape, deltas) in shapeDeltas {
            let w = weights[shape]
            guard w > 1e-5, deltas.count == out.count else { continue }
            for i in out.indices { out[i] += deltas[i] * w }
        }
        return out
    }

    /// 삼각형 인덱스에서 패치 전용 삼각형(세 정점 모두 패치)만 추려 해시.
    public func patchTriangleHash() -> UInt64 {
        ARKitFaceTopology.patchTriangleHash(indices: indices, patchCount: patchCount)
    }

    /// 셰이프 최대 변위 (m).
    public func maxDisplacement(_ shape: ArkitShape) -> Float {
        (shapeDeltas[shape] ?? []).reduce(0) { max($0, simd_length($1)) }
    }

    /// 삼각형 코너 UV (cornerUVs 가 없으면 정점 UV 에서 복제).
    public var effectiveCornerUVs: [SIMD2<Float>] {
        if let c = cornerUVs, c.count == indices.count { return c }
        return indices.map { uvs[Int($0)] }
    }

    /// 렌더용 분할 메시: (정점, UV) 쌍이 다른 코너를 별도 정점으로. `sourceIndex[k]` = 분할 정점 k 의 원본 정점.
    public struct RenderMesh: Sendable {
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]
        public var uvs: [SIMD2<Float>]
        public var indices: [UInt32]
        public var sourceIndex: [Int32]
        public var vertexCount: Int { positions.count }
        /// 원본 정점 배열(델타·Identity 위치)을 분할 정점 배열로.
        public func expand(_ src: [SIMD3<Float>]) -> [SIMD3<Float>] { sourceIndex.map { src[Int($0)] } }
    }

    public func makeRenderMesh() -> RenderMesh {
        let corner = effectiveCornerUVs
        var keyToNew: [UInt64: Int32] = [:]
        var src: [Int32] = [], uvsOut: [SIMD2<Float>] = [], idx: [UInt32] = []
        src.reserveCapacity(positions.count + 512); uvsOut.reserveCapacity(positions.count + 512); idx.reserveCapacity(indices.count)
        for k in indices.indices {
            let v = indices[k], uv = corner[k]
            // 양자화 키: 정점 id + UV(1e-5)
            let qu = UInt64(UInt32(bitPattern: Int32((uv.x * 100000).rounded()))), qv = UInt64(UInt32(bitPattern: Int32((uv.y * 100000).rounded())))
            let key = (UInt64(v) << 40) ^ (qu << 20) ^ qv
            if let n = keyToNew[key], src[Int(n)] == Int32(v), simd_length_squared(uvsOut[Int(n)] - uv) < 1e-10 {
                idx.append(UInt32(n))
            } else {
                let n = Int32(src.count)
                keyToNew[key] = n; src.append(Int32(v)); uvsOut.append(uv); idx.append(UInt32(n))
            }
        }
        let pos = src.map { positions[Int($0)] }
        let nrm = src.map { normals[Int($0)] }
        return RenderMesh(positions: pos, normals: nrm, uvs: uvsOut, indices: idx, sourceIndex: src)
    }
}
