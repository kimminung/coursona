//
//  CaptureBundle.swift
//  CoursonaCore
//
//  iPhone 가이드 캡처 5컷의 **단위·좌표계 규약** (TechPRD §6.3, Prompt M2 지시):
//  - `depth`: Float32, 미터. 카메라 평면으로부터의 거리(ARKit `capturedDepthData.depthMap`, 640×480 기준). 0 또는 NaN = 없음.
//  - `intrinsics`: 저장된 RGB 이미지 해상도 기준 픽셀 단위(fx, fy, cx, cy). 깊이 해상도로 쓸 때는 `scaled(toWidth:height:)`.
//  - `cameraTransform`: 카메라 → ARKit 월드 (`ARCamera.transform`). 카메라는 −Z 를 본다.
//  - `faceTransform`: 얼굴 앵커 → ARKit 월드 (`ARFaceAnchor.transform`). 얼굴 좌표계: 원점은 머리 뒤쪽 중심, +X 피사체 왼쪽, +Y 위, +Z 얼굴 앞.
//  - `faceVertices`: 얼굴 좌표계, 1220개, 미터. 8프레임 평균(지터 제거).
//  - `blendShapes`: 촬영 순간 ARKit 52 가중치(8프레임 평균).
//  - `light`: `ARDirectionalLightEstimate` — ambientIntensity(lm), ambientColorTemperature(K), primaryLightDirection(월드, 단위벡터), primaryLightIntensity(lm).
//  - 이미지: JPEG(긴 변 4032 이하, EXIF 업라이트로 저장 → 픽셀 데이터가 이미 바른 방향). intrinsics 는 이 저장 방향 기준이다.
//  폴더: Documents/Captures/<uuid>/{meta.json, shot-<i>.jpg, depth-<i>.f32}. 전송·테스트용 `.coursonacapture` = 이 폴더의 zip.
//

import Foundation
import simd

/// 캡처 컷 종류. 필수 5(front·left·right·up·smile) + 선택 2(eyesClosed·mouthOpen, TechPRD §6.3 C3·F7).
/// 선택 2는 `CaptureGuide.skip()` 으로 건너뛸 수 있고, 있으면 `CoursonaFit.UserShapeDeltas`(F7)가 eyeBlink·jawOpen
/// 패치 델타를 사용자 것으로 직접 치환한다.
public enum ShotKind: String, CaseIterable, Codable, Sendable {
    case front, left, right, up, smile
    case eyesClosed, mouthOpen

    public var title: String {
        switch self {
        case .front: "정면 중립"
        case .left: "왼쪽 30°"
        case .right: "오른쪽 30°"
        case .up: "위 15°"
        case .smile: "정면 미소"
        case .eyesClosed: "눈 감기 (선택)"
        case .mouthOpen: "입 벌림 (선택)"
        }
    }
    /// 가이드 목표 yaw/pitch (도). yaw + = 피사체가 자기 왼쪽으로 고개를 돌림(카메라에서 보면 오른쪽 뺨이 보임).
    public var targetYawPitch: (yaw: Float, pitch: Float) {
        switch self {
        case .front, .smile, .eyesClosed, .mouthOpen: (0, 0)
        case .left: (30, 0)
        case .right: (-30, 0)
        case .up: (0, 15)
        }
    }
    public var isNeutralRequired: Bool { self == .front || self == .left || self == .right || self == .up }
    /// 필수 5 가 아니라 건너뛸 수 있는 선택 컷인가.
    public var isOptional: Bool { self == .eyesClosed || self == .mouthOpen }
}

/// 깊이 맵 (Float32, m).
public struct DepthMap: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var values: [Float]
    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width; self.height = height; self.values = values
    }
    public subscript(x: Int, y: Int) -> Float { values[y * width + x] }
    /// 유효 깊이(0 < d < 10 m).
    public func isValid(_ d: Float) -> Bool { d.isFinite && d > 0.01 && d < 10 }
    /// 쌍선형 샘플 (유효하지 않은 이웃은 제외). 픽셀 좌표, 픽셀 중심 = (x + 0.5, y + 0.5).
    public func sample(_ p: SIMD2<Float>) -> Float? {
        let q = p - SIMD2<Float>(0.5, 0.5)
        let x0 = Int(q.x.rounded(.down)), y0 = Int(q.y.rounded(.down))
        guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return nil }
        let fx = q.x - Float(x0), fy = q.y - Float(y0)
        var sum: Float = 0, wsum: Float = 0
        for (dx, dy, w) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
            let d = self[x0 + dx, y0 + dy]
            if isValid(d) { sum += d * w; wsum += w }
        }
        return wsum > 0.25 ? sum / wsum : nil
    }
}

/// RGBA8 이미지 (순수 값 타입; 인코딩은 CoursonaIO).
public struct RGBAImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bytes: [UInt8]
    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width; self.height = height; self.bytes = bytes
    }
    public init(width: Int, height: Int, fill: SIMD4<UInt8> = SIMD4(0, 0, 0, 255)) {
        self.width = width; self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { bytes[i * 4] = fill.x; bytes[i * 4 + 1] = fill.y; bytes[i * 4 + 2] = fill.z; bytes[i * 4 + 3] = fill.w }
    }
    public subscript(x: Int, y: Int) -> SIMD4<UInt8> {
        get { let i = (y * width + x) * 4; return SIMD4(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) }
        set { let i = (y * width + x) * 4; bytes[i] = newValue.x; bytes[i + 1] = newValue.y; bytes[i + 2] = newValue.z; bytes[i + 3] = newValue.w }
    }
    /// 0…1 선형 색 샘플 (쌍선형). 픽셀 중심 = (x + 0.5, y + 0.5) 규약 (래스터라이저와 동일).
    public func sample(_ p: SIMD2<Float>) -> SIMD4<Float>? {
        let q = p - SIMD2<Float>(0.5, 0.5)
        let x0 = Int(q.x.rounded(.down)), y0 = Int(q.y.rounded(.down))
        guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return nil }
        let fx = q.x - Float(x0), fy = q.y - Float(y0)
        func c(_ x: Int, _ y: Int) -> SIMD4<Float> { SIMD4<Float>(self[x, y]) / 255 }
        let top = c(x0, y0) * (1 - fx) + c(x0 + 1, y0) * fx
        let bot = c(x0, y0 + 1) * (1 - fx) + c(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bot * fy
    }
}

/// 조명 추정 (ARDirectionalLightEstimate).
public struct LightEstimate: Codable, Sendable, Equatable {
    public var ambientIntensity: Float      // lm (1000 = 보통 실내)
    public var ambientColorTemperature: Float // K
    public var primaryDirection: [Float]?   // 월드 단위벡터 (빛이 진행하는 방향)
    public var primaryIntensity: Float?
    public init(ambientIntensity: Float = 1000, ambientColorTemperature: Float = 6500, primaryDirection: [Float]? = nil, primaryIntensity: Float? = nil) {
        self.ambientIntensity = ambientIntensity; self.ambientColorTemperature = ambientColorTemperature
        self.primaryDirection = primaryDirection; self.primaryIntensity = primaryIntensity
    }
}

/// 기기 물리적 방향(T-306, `UIDeviceOrientation` 과 같은 뜻) — 기록용. `CaptureShotMeta.orientation` 참고.
public enum CaptureOrientation: String, Codable, Sendable, Equatable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown, unknown
}

/// 한 컷의 메타데이터 (meta.json 에 들어간다). 픽셀 데이터는 별도 파일.
public struct CaptureShotMeta: Codable, Sendable, Equatable {
    public var kind: ShotKind
    public var imageFile: String
    public var depthFile: String?
    /// 썸네일 파일 (긴 변 `CaptureBundleStore.thumbnailMaxDimension`, JPEG). 옛 번들에는 없다.
    public var thumbFile: String?
    public var imageWidth: Int
    public var imageHeight: Int
    public var depthWidth: Int?
    public var depthHeight: Int?
    public var intrinsics: Geometry.Intrinsics
    public var cameraTransform: Matrix4Codable
    public var faceTransform: Matrix4Codable
    /// 1220 × xyz (평평하게 3660 개)
    public var faceVertices: [Float]
    public var blendShapes: ArkitWeights
    public var light: LightEstimate
    /// 평균에 쓴 프레임 수
    public var averagedFrames: Int
    public var timestamp: Double

    // --- 희소 캡처(TrueDepth 없음 · Mac 카메라 · 사진 파일, T-205) 전용. ARKit 캡처에서는 모두 nil. ---
    /// Vision 얼굴 랜드마크(revision 3 = 76점) 전부, 저장 이미지 **픽셀 좌표**(x 오른쪽, y 아래), 평평하게 x,y 반복. N 프레임 평균.
    public var landmarks2D: [Float]?
    /// 템플릿 `LandmarkName` 과 같은 이름의 핵심점(픽셀). 눈 꼬리 4·코끝·입꼬리 2·턱끝. 좌/우는 **피사체 기준**(비반전 이미지에서 피사체 왼쪽 = 이미지 오른쪽).
    public var keyPoints2D: [String: [Float]]?
    /// 얼굴 상자(픽셀, x·y·w·h)
    public var faceBox: [Float]?
    /// 자세 추정 (yaw·pitch·roll, 도). 부호는 ARKit 경로와 같다: yaw + = 피사체가 자기 왼쪽으로, pitch + = 위.
    public var poseEstimate: [Float]?
    /// intrinsics 가 센서값이 아니라 가정 FOV 로 추정된 값이면 true (Mac 은 `videoFieldOfView` 가 없다)
    public var intrinsicsEstimated: Bool?
    /// T-306: 촬영 순간 기기의 물리적 방향(iPad 가로 거치 등). **피팅·캡처 로직은 이 값을 읽지 않는다** — 영상·깊이는
    /// 지금도 늘 세로로 처리한다(`FaceCaptureSession`/`PhotoCaptureSession` 의 포트레이트 회전 규약, 초상의 회전 버그 재발 방지).
    /// 진단·추후 실제 가로 지원을 위한 기록용 필드. 없으면(옛 번들) nil.
    public var orientation: CaptureOrientation?

    public init(kind: ShotKind, imageFile: String, depthFile: String?, imageWidth: Int, imageHeight: Int, depthWidth: Int?, depthHeight: Int?,
                intrinsics: Geometry.Intrinsics, cameraTransform: simd_float4x4, faceTransform: simd_float4x4,
                faceVertices: [SIMD3<Float>], blendShapes: ArkitWeights, light: LightEstimate, averagedFrames: Int, timestamp: Double,
                landmarks2D: [SIMD2<Float>]? = nil, keyPoints2D: [LandmarkName: SIMD2<Float>]? = nil, faceBox: CGRect? = nil,
                poseEstimate: SIMD3<Float>? = nil, intrinsicsEstimated: Bool? = nil, orientation: CaptureOrientation? = nil) {
        self.kind = kind; self.imageFile = imageFile; self.depthFile = depthFile
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.depthWidth = depthWidth; self.depthHeight = depthHeight
        self.intrinsics = intrinsics; self.cameraTransform = Matrix4Codable(cameraTransform); self.faceTransform = Matrix4Codable(faceTransform)
        self.faceVertices = faceVertices.flatMap { [$0.x, $0.y, $0.z] }
        self.blendShapes = blendShapes; self.light = light; self.averagedFrames = averagedFrames; self.timestamp = timestamp
        self.landmarks2D = landmarks2D?.flatMap { [$0.x, $0.y] }
        self.keyPoints2D = keyPoints2D.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, [$0.value.x, $0.value.y]) }) }
        self.faceBox = faceBox.map { [Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)] }
        self.poseEstimate = poseEstimate.map { [$0.x, $0.y, $0.z] }
        self.intrinsicsEstimated = intrinsicsEstimated
        self.orientation = orientation
    }

    public var faceVertexArray: [SIMD3<Float>] {
        stride(from: 0, to: faceVertices.count - 2, by: 3).map { SIMD3(faceVertices[$0], faceVertices[$0 + 1], faceVertices[$0 + 2]) }
    }
    /// 희소 캡처 랜드마크 (픽셀). ARKit 캡처면 빈 배열.
    public var landmarkArray: [SIMD2<Float>] {
        guard let l = landmarks2D, l.count >= 2 else { return [] }
        return stride(from: 0, to: l.count - 1, by: 2).map { SIMD2(l[$0], l[$0 + 1]) }
    }
    /// 핵심점 조회 (픽셀).
    public func keyPoint(_ name: LandmarkName) -> SIMD2<Float>? {
        guard let v = keyPoints2D?[name.rawValue], v.count == 2 else { return nil }
        return SIMD2(v[0], v[1])
    }
    /// ARKit 밀집 메시 없이 사진·랜드마크만 있는 컷인가.
    public var isSparse: Bool { faceVertices.isEmpty && landmarks2D != nil }
}

/// 번들 메타 (meta.json).
public struct CaptureBundleMeta: Codable, Sendable, Equatable {
    public var schema: Int = 1
    public var id: UUID
    public var createdAt: Date
    public var device: String
    /// TrueDepth 없이 사진+Vision 만으로 만든 번들이면 true (희소 피팅)
    public var sparse: Bool
    /// ARKit 삼각형 인덱스 해시(실기기) — 템플릿 패치와 비교
    public var arkitTriangleHash: String?
    public var arkitVertexCount: Int
    public var shots: [CaptureShotMeta]

    public init(id: UUID = UUID(), createdAt: Date = Date(), device: String, sparse: Bool, arkitTriangleHash: String?, arkitVertexCount: Int, shots: [CaptureShotMeta]) {
        self.id = id; self.createdAt = createdAt; self.device = device; self.sparse = sparse
        self.arkitTriangleHash = arkitTriangleHash; self.arkitVertexCount = arkitVertexCount; self.shots = shots
    }
}

/// 한 컷 (메타 + 픽셀). 피팅·텍스처 입력.
public struct CaptureShot: Sendable {
    public var meta: CaptureShotMeta
    public var image: RGBAImage?
    public var depth: DepthMap?
    /// 목록·확인용 작은 이미지 (저장 시 `CaptureBundleStore` 가 만들고, 읽을 때 되살린다).
    public var thumbnail: RGBAImage?
    public init(meta: CaptureShotMeta, image: RGBAImage?, depth: DepthMap?, thumbnail: RGBAImage? = nil) {
        self.meta = meta; self.image = image; self.depth = depth; self.thumbnail = thumbnail
    }

    public var kind: ShotKind { meta.kind }
    public var cameraTransform: simd_float4x4 { meta.cameraTransform.m }
    public var faceTransform: simd_float4x4 { meta.faceTransform.m }
    /// 얼굴 정점을 월드 좌표로.
    public var faceVerticesWorld: [SIMD3<Float>] { meta.faceVertexArray.map { Geometry.transformPoint(meta.faceTransform.m, $0) } }
    /// 깊이 해상도 기준 intrinsics.
    public var depthIntrinsics: Geometry.Intrinsics? {
        guard let d = depth else { return nil }
        return meta.intrinsics.scaled(toWidth: d.width, height: d.height)
    }
}

/// 캡처 번들 (인메모리).
public struct CaptureBundle: Sendable {
    public var meta: CaptureBundleMeta
    public var shots: [CaptureShot]
    public init(meta: CaptureBundleMeta, shots: [CaptureShot]) { self.meta = meta; self.shots = shots }

    public func shot(_ kind: ShotKind) -> CaptureShot? { shots.first { $0.kind == kind } }
    public var neutralShots: [CaptureShot] { shots.filter { $0.kind.isNeutralRequired } }
}
