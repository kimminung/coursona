//
//  PhotoCaptureSession.swift
//  CoursonaCapture
//
//  희소(폴백) 캡처 (TechPRD §6.3 폴백, T-205): TrueDepth 가 없는 **Mac 내장 카메라** · iPhone 폴백 · **사진 파일** 에서
//  AVCapture 프레임(또는 CGImage) → Vision 얼굴 랜드마크(revision 3 = 76점) + 자세 → `CaptureShot`(RGB · 랜드마크 · 핵심점 · 추정 intrinsics/faceTransform, 깊이·1220 정점 없음).
//  번들 메타는 `sparse = true`. 밀집 피팅은 불가하고 M3 T-306 희소 피팅의 입력이 된다.
//  좌표·부호 규약은 `SparseFaceGeometry` 참고. 미리보기 반전은 뷰에서만 한다 — 저장 이미지는 비반전.
//

import Foundation
import simd
import CoursonaCore
#if os(macOS) || os(iOS)
@preconcurrency import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation

/// 프레임 요약 (가이드 UI 용).
public struct PhotoFrameStatus: Sendable, Equatable {
    public var isTracked = false
    public var yaw: Float = 0        // 도, 우리 규약 (SparseFaceGeometry.pose)
    public var pitch: Float = 0
    public var roll: Float = 0
    public var visionYaw: Float = 0  // Vision 원값(도) — 부호 규약 실기기 확인용 🧪
    public var visionPitch: Float = 0
    public var brightness: Float = 0 // 얼굴 상자 평균 밝기 0…1
    public var faceWidthRatio: Float = 0 // 얼굴 상자 폭 / 이미지 폭
    public var landmarkCount = 0
    public var imageWidth = 0
    public var imageHeight = 0
    public var confidence: Float = 0
}

/// 희소 캡처 게이트.
public struct PhotoCaptureGate: Sendable, Equatable {
    /// ARKit 경로(`CaptureGate`)와 같은 이유로 19차에 ±8/±7 → ±12/±10 (Vision 자세는 ARKit 보다 노이즈가 커 조금 더 좁게 둔다).
    public var yawTolerance: Float = 12
    public var pitchTolerance: Float = 10
    public var brightnessRange: ClosedRange<Float> = 0.22...0.85
    public var minFaceWidthRatio: Float = 0.16
    public var framesToAverage = 8
    public var holdSeconds: Double = 0.5
    public init() {}
}

/// 한 프레임의 Vision 분석 결과 (내부 전달용).
struct PhotoFaceAnalysis: Sendable {
    var points: [SIMD2<Float>]            // allPoints, 픽셀(원점 왼쪽 위)
    var keyPoints: [LandmarkName: SIMD2<Float>]
    var box: CGRect
    var pose: SIMD3<Float>                // 우리 규약 (도)
    var visionYawPitch: SIMD2<Float>
    var confidence: Float
    var width: Int
    var height: Int
}

@MainActor
@Observable
public final class PhotoCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public private(set) var status = PhotoFrameStatus()
    public private(set) var errorText: String?
    public private(set) var isRunning = false
    public private(set) var cameraName = "—"
    /// 최근 프레임 (뷰가 그대로 표시; 비반전)
    public private(set) var preview: CGImage?
    /// 오버레이용 최근 랜드마크(픽셀)·얼굴 상자
    public private(set) var previewLandmarks: [SIMD2<Float>] = []
    public private(set) var previewBox: CGRect?
    public private(set) var previewKeyPoints: [LandmarkName: SIMD2<Float>] = [:]
    public var gate = PhotoCaptureGate()
    /// 가정 수평 FOV (도). Mac 은 센서 FOV 를 못 읽어 이 값을 쓴다. iOS 는 `videoFieldOfView` 가 있으면 그 값으로 덮어쓴다.
    public var assumedHorizontalFOV: Float = SparseFaceGeometry.assumedMacHorizontalFOV
    public private(set) var fovIsMeasured = false

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "coursona.photo-capture", qos: .userInitiated)
    private let busy = BusyFlag()
    private var recent: [PhotoFaceAnalysis] = []
    private var latestImage: CGImage?
    private var latestAnalysis: PhotoFaceAnalysis?
    private var configured = false

    /// 카메라가 하나라도 있는가 (시뮬레이터는 없다 — 사진 불러오기만 가능).
    public static var hasCamera: Bool { AVCaptureDevice.systemPreferredCamera != nil || AVCaptureDevice.default(for: .video) != nil }

    public override init() { super.init() }

    // MARK: 세션 수명

    public func start() {
        errorText = nil
        Task { @MainActor in
            let st = AVCaptureDevice.authorizationStatus(for: .video)
            var ok = st == .authorized
            if st == .notDetermined { ok = await AVCaptureDevice.requestAccess(for: .video) }
            guard ok else { errorText = "카메라 권한이 없습니다 — 시스템 설정 › 개인정보 보호 › 카메라에서 초상을 허용하세요."; return }
            do { try configureIfNeeded() } catch { errorText = error.localizedDescription; return }
            let s = session
            queue.async { s.startRunning() }
            isRunning = true
        }
    }

    public func stop() {
        let s = session
        queue.async { s.stopRunning() }
        isRunning = false
        recent.removeAll()
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.systemPreferredCamera
        #else
        let device = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
        #endif
        guard let device else { throw NSError(domain: "Coursona", code: 1, userInfo: [NSLocalizedDescriptionKey: "사용할 수 있는 카메라가 없습니다 (시뮬레이터면 '사진 불러오기' 를 쓰세요)."]) }
        cameraName = device.localizedName
        #if os(iOS)
        let fov = device.activeFormat.videoFieldOfView
        if fov > 1 { assumedHorizontalFOV = fov; fovIsMeasured = true }
        #endif
        session.beginConfiguration()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "Coursona", code: 2, userInfo: [NSLocalizedDescriptionKey: "카메라 입력을 추가할 수 없습니다."]) }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw NSError(domain: "Coursona", code: 3, userInfo: [NSLocalizedDescriptionKey: "비디오 출력을 추가할 수 없습니다."]) }
        session.addOutput(output)
        if let conn = output.connection(with: .video) {
            // 저장 이미지는 비반전(ARKit 경로와 동일). 미리보기 거울 효과는 뷰에서.
            if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = false }
            #if os(iOS)
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }   // 포트레이트 업라이트
            #endif
        }
        session.commitConfiguration()
        configured = true
    }

    // MARK: 프레임 → Vision

    nonisolated public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), busy.tryAcquire() else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = Self.sharedContext.createCGImage(ci, from: ci.extent) else { busy.release(); return }
        let flag = busy
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { flag.release() }
            let analysis = try? await Self.analyze(cg)
            guard let strong = self else { return }
            await MainActor.run { strong.ingest(image: cg, analysis: analysis) }
        }
    }

    nonisolated static let sharedContext = CIContext(options: [.cacheIntermediates: false])

    /// CGImage 한 장을 Vision 으로 분석한다 (카메라 프레임·사진 파일 공용). 얼굴이 없으면 nil.
    nonisolated static func analyze(_ cg: CGImage) async throws -> PhotoFaceAnalysis? {
        let req = DetectFaceLandmarksRequest(.revision3)   // 76점 고정 (template.json 랜드마크 대응 인덱스 안정)
        let faces = try await req.perform(on: cg)
        // 가장 큰 얼굴 하나
        guard let f = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }), let lm = f.landmarks else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        func px(_ r: FaceObservation.Landmarks2D.Region) -> [SIMD2<Float>] { r.pointsInImageCoordinates(size, origin: .upperLeft).map { SIMD2(Float($0.x), Float($0.y)) } }
        let key = SparseFaceGeometry.keyPoints(eyeA: px(lm.leftEye), eyeB: px(lm.rightEye), nose: px(lm.nose), noseCrest: px(lm.noseCrest),
                                               lipsOuter: px(lm.outerLips), contour: px(lm.faceContour))
        let vy = Float(f.yaw.converted(to: .degrees).value), vp = Float(f.pitch.converted(to: .degrees).value), vr = Float(f.roll.converted(to: .degrees).value)
        let pose = SparseFaceGeometry.pose(visionYaw: vy, visionPitch: vp, visionRoll: vr, keyPoints: key)
        let box = f.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        return PhotoFaceAnalysis(points: px(lm.allPoints), keyPoints: key, box: box, pose: pose, visionYawPitch: SIMD2(vy, vp),
                                 confidence: f.confidence, width: cg.width, height: cg.height)
    }

    /// 얼굴 상자 평균 밝기 (0…1, sRGB 평균).
    nonisolated static func brightness(_ cg: CGImage, in box: CGRect) -> Float {
        let ci = CIImage(cgImage: cg)
        // CIImage 는 원점이 왼쪽 아래 → 상자 y 뒤집기
        let flipped = CGRect(x: box.minX, y: CGFloat(cg.height) - box.maxY, width: box.width, height: box.height).intersection(ci.extent)
        guard !flipped.isEmpty else { return 0 }
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = flipped
        guard let out = filter.outputImage else { return 0 }
        var rgba = [UInt8](repeating: 0, count: 4)
        sharedContext.render(out, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Float(rgba[0]) * 0.2126 + Float(rgba[1]) * 0.7152 + Float(rgba[2]) * 0.0722) / 255
    }

    private func ingest(image: CGImage, analysis: PhotoFaceAnalysis?) {
        latestImage = image
        preview = image
        guard let a = analysis else {
            status.isTracked = false
            status.imageWidth = image.width; status.imageHeight = image.height
            previewLandmarks = []; previewBox = nil; previewKeyPoints = [:]
            latestAnalysis = nil
            return
        }
        latestAnalysis = a
        recent.append(a)
        if recent.count > gate.framesToAverage { recent.removeFirst() }
        previewLandmarks = a.points
        previewBox = a.box
        previewKeyPoints = a.keyPoints
        let b = Self.brightness(image, in: a.box)
        status = PhotoFrameStatus(isTracked: true, yaw: a.pose.x, pitch: a.pose.y, roll: a.pose.z, visionYaw: a.visionYawPitch.x, visionPitch: a.visionYawPitch.y,
                                  brightness: b, faceWidthRatio: Float(a.box.width) / Float(max(1, image.width)), landmarkCount: a.points.count,
                                  imageWidth: image.width, imageHeight: image.height, confidence: a.confidence)
    }

    // MARK: 촬영

    /// 최근 N 프레임 평균 랜드마크·자세로 한 컷. 이미지는 마지막 프레임.
    public func captureShot(kind: ShotKind) -> CaptureShot? {
        guard let image = latestImage, !recent.isEmpty, let last = latestAnalysis else { return nil }
        let same = recent.filter { $0.points.count == last.points.count && $0.width == last.width && $0.height == last.height }
        return makeShot(kind: kind, image: image, frames: same.isEmpty ? [last] : same, timestamp: Date().timeIntervalSince1970)
    }

    /// 사진 파일 한 장 → 한 컷 (Mac 에서 파일 불러오기, 시뮬레이터). 얼굴이 없으면 nil.
    public func makeShot(kind: ShotKind, from image: CGImage) async -> CaptureShot? {
        guard let a = try? await Self.analyze(image) else { return nil }
        // 미리보기도 이 사진으로 바꾼다
        ingest(image: image, analysis: a)
        return makeShot(kind: kind, image: image, frames: [a], timestamp: Date().timeIntervalSince1970)
    }

    private func makeShot(kind: ShotKind, image: CGImage, frames: [PhotoFaceAnalysis], timestamp: Double) -> CaptureShot? {
        guard let first = frames.first else { return nil }
        let n = Float(frames.count)
        var pts = [SIMD2<Float>](repeating: .zero, count: first.points.count)
        var pose = SIMD3<Float>.zero
        var key: [LandmarkName: SIMD2<Float>] = [:]
        var box = CGRect.zero
        for f in frames {
            for i in pts.indices { pts[i] += f.points[i] / n }
            pose += f.pose / n
            for (k, v) in f.keyPoints { key[k, default: .zero] += v / n }
            box = CGRect(x: box.minX + f.box.minX / CGFloat(n), y: box.minY + f.box.minY / CGFloat(n), width: box.width + f.box.width / CGFloat(n), height: box.height + f.box.height / CGFloat(n))
        }
        let width = image.width, height = image.height
        guard let rgba = Self.rgba(image) else { return nil }
        let K = SparseFaceGeometry.intrinsics(horizontalFOVDegrees: assumedHorizontalFOV, width: width, height: height)
        var faceT = matrix_identity_float4x4
        if let eyes = SparseFaceGeometry.eyeCenters(key) {
            faceT = SparseFaceGeometry.estimateFaceTransform(eyeLeft: eyes.left, eyeRight: eyes.right, poseDegrees: pose, intrinsics: K)
        }
        let bright = Self.brightness(image, in: box)
        // 조명: 방향 추정 없음. 밝기 0…1 을 대략 0…2000 lm 으로 — 피팅이 아니라 UI 참고용.
        let light = LightEstimate(ambientIntensity: bright * 2000, ambientColorTemperature: 6500, primaryDirection: nil, primaryIntensity: nil)
        let meta = CaptureShotMeta(kind: kind, imageFile: "shot-\(kind.rawValue).jpg", depthFile: nil, imageWidth: width, imageHeight: height, depthWidth: nil, depthHeight: nil,
                                   intrinsics: K, cameraTransform: matrix_identity_float4x4, faceTransform: faceT,
                                   faceVertices: [], blendShapes: ArkitWeights(), light: light, averagedFrames: frames.count, timestamp: timestamp,
                                   landmarks2D: pts, keyPoints2D: key, faceBox: box, poseEstimate: pose, intrinsicsEstimated: !fovIsMeasured)
        return CaptureShot(meta: meta, image: rgba, depth: nil)
    }

    nonisolated static func rgba(_ cg: CGImage) -> RGBAImage? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RGBAImage(width: w, height: h, bytes: buf) : nil
    }

    /// 조도 경고 문장 (T-203 배너). 문제없으면 nil.
    public var lightWarning: String? {
        guard status.isTracked else { return nil }
        let b = status.brightness
        if b < gate.brightnessRange.lowerBound { return String(format: "너무 어둡습니다 (밝기 %.2f) — 밝은 곳으로", b) }
        if b > gate.brightnessRange.upperBound { return String(format: "너무 밝습니다 (밝기 %.2f) — 역광을 피하세요", b) }
        if status.faceWidthRatio < gate.minFaceWidthRatio { return "카메라에 조금 더 가까이" }
        return nil
    }

    /// 지금 프레임이 게이트를 통과하는가 (ARKit 경로 `passesGate` 와 같은 문장).
    public func passesGate(for kind: ShotKind) -> (ok: Bool, reason: String) {
        guard status.isTracked else { return (false, "얼굴을 찾는 중") }
        if status.faceWidthRatio < gate.minFaceWidthRatio { return (false, "카메라에 조금 더 가까이") }
        let (ty, tp) = kind.targetYawPitch
        if abs(status.yaw - ty) > gate.yawTolerance { return (false, status.yaw < ty ? "고개를 조금 더 왼쪽으로" : "고개를 조금 더 오른쪽으로") }
        if abs(status.pitch - tp) > gate.pitchTolerance { return (false, status.pitch < tp ? "턱을 조금 들어 주세요" : "턱을 조금 내려 주세요") }
        if !gate.brightnessRange.contains(status.brightness) { return (false, status.brightness < gate.brightnessRange.lowerBound ? "조금 더 밝은 곳으로" : "너무 밝습니다") }
        return (true, "유지하세요")
    }

    /// 번들 메타의 기기 문자열.
    public static var deviceDescription: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return "Mac \(model) (사진 폴백)"
        #else
        return "iOS 사진 폴백"
        #endif
    }
}

/// Vision 분석이 겹치지 않게 하는 플래그 (프레임은 버린다).
final class BusyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func tryAcquire() -> Bool { lock.lock(); defer { lock.unlock() }; if busy { return false }; busy = true; return true }
    func release() { lock.lock(); busy = false; lock.unlock() }
}
#endif
