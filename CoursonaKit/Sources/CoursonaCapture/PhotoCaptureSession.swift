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
    /// 선택 컷 게이트(C3·F7, B 등급): 눈 종횡비(높이/폭, 평균) · 입 벌림 비율(안쪽 입술 높이 / 바깥 입술 폭).
    public var eyeAspectRatio: Float = 1
    public var mouthOpenRatio: Float = 0
    /// T-302: 캡처 품질 점수(`DetectFaceCaptureQualityRequest`, 0…1 — 조명·선명도·중앙 위치) · 얼굴 상자 안 인물 매트 비율
    /// (`GeneratePersonSegmentationRequest`, 그리드 샘플링 — 전체 매트 저장은 OS 27+ 필요해 아직 안 함, §PersonCoverage.swift).
    public var captureQualityScore: Float = 1
    public var personCoverage: Float = 1
    /// C6(T-602) `VisionFaceDriver` 용 추가 원시 기하값 — 여기선 순수 측정만, 중립 캘리브레이션·필터링은 드라이버(상태 보유) 책임.
    /// 눈 종횡비를 좌우로 나눈 값(`eyeAspectRatio` 는 평균) — 짝눈 깜빡임 구분용.
    public var eyeAspectRatioLeft: Float = 1
    public var eyeAspectRatioRight: Float = 1
    /// 바깥 입술 폭 / 얼굴 상자 폭 — 웃음(폭 넓어짐)·오므림(폭 좁아짐) 구분용 원시값.
    public var mouthWidthRatio: Float = 0
    /// 안쪽 입술 높이/폭 — 커지면(원형에 가까워지면) 오므림·펀넬 쪽 신호.
    public var innerLipsAspect: Float = 0
    /// 눈썹 중심 ↔ 눈 중심 세로 거리 / 얼굴 상자 폭 — 커지면 눈썹 올라감, 작아지면(또는 음수) 눈썹 내려감.
    public var browRaiseLeft: Float = 0
    public var browRaiseRight: Float = 0
    /// 동공 위치 ↔ 눈 상자 중심, 눈 상자 반폭·반높이로 정규화한 좌우 평균(-1…1 근방). 부호 규약은 🧪 실기기 미확인.
    public var gazeX: Float = 0
    public var gazeY: Float = 0
}

/// 희소 캡처 게이트.
public struct PhotoCaptureGate: Sendable, Equatable {
    /// ARKit 경로(`CaptureGate`)와 같은 이유로 19차에 ±8/±7 → ±12/±10 → 20차 ±18/±14 (Vision 자세는 ARKit 보다 노이즈가 커 ARKit 경로보다 조금 더 좁게 둔다).
    public var yawTolerance: Float = 18
    public var pitchTolerance: Float = 14
    public var brightnessRange: ClosedRange<Float> = 0.22...0.85
    public var minFaceWidthRatio: Float = 0.16
    public var framesToAverage = 8
    public var holdSeconds: Double = 0.5
    /// 선택 컷(C3·F7) 임계값 — TechPRD §6.3: 눈 감기 `종횡비 < 0.12`, 입 벌림 `안쪽/바깥 입술 폭 > 0.25`. 20차: ARKit 경로와 같은
    /// 이유로 완화(0.12→0.17 · 0.25→0.18).
    public var eyesClosedMaxAspect: Float = 0.17
    public var mouthOpenMinRatio: Float = 0.18
    /// T-302: 캡처 품질 점수 ≥ 0.5(TechPRD §6.3), 얼굴 상자 인물 매트 비율 ≥ 0.5. 원래 0.6(TechPRD 초안) 이었으나,
    /// 조명이 한쪽으로 치우치면 그림자 진 쪽 마스크 신뢰도가 떨어져(`PersonCoverage.ratio` 참고 — 원값 평균으로 바꿔도
    /// 평균 자체가 내려가는 건 못 막는다) 정상적인 단독 인물 사진도 자주 막히는 사용자 피드백으로 20차에 완화.
    public var minCaptureQuality: Float = 0.5
    public var minPersonCoverage: Float = 0.5
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
    /// 선택 컷 게이트용(C3·F7) — `PhotoFrameStatus` 와 같은 정의.
    var eyeAspectRatio: Float
    var mouthOpenRatio: Float
    /// T-302 — `PhotoFrameStatus` 와 같은 정의. `nil` = 이 프레임은 비싼 Vision 요청(아래 `analyze(scoreQuality:)`)을
    /// 건너뛰었다는 뜻 — `ingest` 가 직전 값을 그대로 들고 간다.
    var captureQualityScore: Float?
    var personCoverage: Float?
    /// T-602 — `PhotoFrameStatus` 와 같은 정의.
    var eyeAspectRatioLeft: Float
    var eyeAspectRatioRight: Float
    var mouthWidthRatio: Float
    var innerLipsAspect: Float
    var browRaiseLeft: Float
    var browRaiseRight: Float
    var gazeX: Float
    var gazeY: Float
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
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        // T-604(C8 UI 2단계) 실기기·시뮬레이터 둘 다에서 재현된 크래시 둘:
        // 1) `stop()`이 `queue.async { stopRunning() }`를 올리는 동안 `beginConfiguration()...commitConfiguration()`
        //    가 메인 액터에서 따로(동기적으로) 돌면, 뒤로 가기로 두 호출이 겹치면 "stopRunning may not be called
        //    between beginConfiguration and commitConfiguration" 로 바로 죽는다. Apple 권장대로 세션을 만지는
        //    호출을 전부 같은 전용 큐에 직렬로 올려서 겹칠 수 없게 한다(`stop()`의 `stopRunning()`도 같은 큐).
        // 2) 그 다음 실기기 재확인(`RunCodeSnippet`/시뮬레이터 둘 다)으로 또 다른 경로를 찾았다: 시뮬레이터처럼
        //    `canAddInput`/`canAddOutput` 이 실패하면 옛 코드는 `commitConfiguration()` 을 **안 부르고** 바로
        //    throw 해서, 세션이 "구성 중" 상태로 영영 멈춰 버린다 — 그 뒤 아무 `stop()` 이나 똑같이 크래시한다.
        //    `defer` 로 성공·실패 어느 경로든 beginConfiguration 과 반드시 짝을 맞춘다.
        try queue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .high
            guard session.canAddInput(input) else { throw NSError(domain: "Coursona", code: 2, userInfo: [NSLocalizedDescriptionKey: "카메라 입력을 추가할 수 없습니다."]) }
            session.addInput(input)
            guard session.canAddOutput(output) else { throw NSError(domain: "Coursona", code: 3, userInfo: [NSLocalizedDescriptionKey: "비디오 출력을 추가할 수 없습니다."]) }
            session.addOutput(output)
            if let conn = output.connection(with: .video) {
                // 저장 이미지는 비반전(ARKit 경로와 동일). 미리보기 거울 효과는 뷰에서.
                if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = false }
                #if os(iOS)
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }   // 포트레이트 업라이트
                #endif
            }
        }
        configured = true
    }

    // MARK: 프레임 → Vision

    nonisolated public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), busy.tryAcquire() else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = Self.sharedContext.createCGImage(ci, from: ci.extent) else { busy.release(); return }
        let flag = busy
        let scoreQuality = throttle.shouldRunExpensive()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { flag.release() }
            let analysis = try? await Self.analyze(cg, scoreQuality: scoreQuality)
            guard let strong = self else { return }
            await MainActor.run { strong.ingest(image: cg, analysis: analysis) }
        }
    }

    nonisolated static let sharedContext = CIContext(options: [.cacheIntermediates: false])
    /// 트루뎁스가 없는 환경(Mac 카메라)에서는 라이브 게이트가 전적으로 이 Vision 파이프라인 속도에 달려 있다.
    /// `DetectFaceCaptureQualityRequest`·`GeneratePersonSegmentationRequest` 둘은 랜드마크 검출보다 훨씬 느려서
    /// (실측 체감: 매 프레임 돌리면 각도·표정 링이 한 박자씩 늦게 따라온다) 매 프레임이 아니라 3프레임에 한 번만
    /// 돌린다 — 각도·표정처럼 매 프레임 반응해야 하는 신호(랜드마크 기반)는 그대로 매 프레임 돈다.
    private let throttle = FrameThrottle(interval: 3)

    /// CGImage 한 장을 Vision 으로 분석한다 (카메라 프레임·사진 파일 공용). 얼굴이 없으면 nil.
    /// `scoreQuality`: 캡처 품질 점수·인물 매트(둘 다 느림)를 이번 호출에서 계산할지. false 면 `nil` 로 돌려주고
    /// `ingest` 가 직전 값을 그대로 쓴다 — 사진 파일 1장(`makeShot(from:)`·`PhotoSuitability`)은 항상 true.
    nonisolated static func analyze(_ cg: CGImage, scoreQuality: Bool = true) async throws -> PhotoFaceAnalysis? {
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
        // 선택 컷 게이트(C3·F7): 눈 종횡비(높이/폭 평균) · 입 벌림(안쪽 입술 높이 / 바깥 입술 폭).
        func bbox(_ pts: [SIMD2<Float>]) -> (w: Float, h: Float) {
            guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return (0, 0) }
            return (x1 - x0, y1 - y0)
        }
        let leftEyeBox = bbox(px(lm.leftEye)), rightEyeBox = bbox(px(lm.rightEye))
        let earLeft = leftEyeBox.h / max(1, leftEyeBox.w), earRight = rightEyeBox.h / max(1, rightEyeBox.w)
        let ear = (earLeft + earRight) / 2
        let innerLipsBox = bbox(px(lm.innerLips)), outerLipsBox = bbox(px(lm.outerLips))
        let mouthOpen = outerLipsBox.w > 1 ? innerLipsBox.h / outerLipsBox.w : 0
        // T-602(VisionFaceDriver) 용 추가 원시 기하값 — 순수 측정만, 의미 부여(중립 대비)는 드라이버 쪽.
        func centroid(_ pts: [SIMD2<Float>]) -> SIMD2<Float> { pts.isEmpty ? .zero : pts.reduce(.zero, +) / Float(pts.count) }
        let faceW = Float(box.width)
        let leftEyeC = centroid(px(lm.leftEye)), rightEyeC = centroid(px(lm.rightEye))
        let leftBrowC = centroid(px(lm.leftEyebrow)), rightBrowC = centroid(px(lm.rightEyebrow))
        let browRaiseLeft = faceW > 1 ? (leftEyeC.y - leftBrowC.y) / faceW : 0
        let browRaiseRight = faceW > 1 ? (rightEyeC.y - rightBrowC.y) / faceW : 0
        let mouthWidthRatio = faceW > 1 ? outerLipsBox.w / faceW : 0
        let innerLipsAspect = innerLipsBox.w > 1 ? innerLipsBox.h / innerLipsBox.w : 0
        var gazeX: Float = 0, gazeY: Float = 0
        if let lp = px(lm.leftPupil).first, let rp = px(lm.rightPupil).first, leftEyeBox.w > 1, leftEyeBox.h > 1, rightEyeBox.w > 1, rightEyeBox.h > 1 {
            let gxL = (lp.x - leftEyeC.x) / (leftEyeBox.w / 2), gyL = (lp.y - leftEyeC.y) / (leftEyeBox.h / 2)
            let gxR = (rp.x - rightEyeC.x) / (rightEyeBox.w / 2), gyR = (rp.y - rightEyeC.y) / (rightEyeBox.h / 2)
            gazeX = (gxL + gxR) / 2; gazeY = (gyL + gyR) / 2
        }
        // T-302: 캡처 품질 점수 · 인물 매트 비율. 그리드 샘플링으로 "이 상자가 실제로 사람인가" 만 본다
        // (`pixel(at:)` 만 OS 26 에서 되고 전체 매트는 OS 27+ 라 — `PersonCoverage.swift` 머리말 참고).
        // 매 프레임 돌리기엔 느려 `scoreQuality` 일 때만 계산하고(throttle, `captureOutput` 참고), 아니면 nil —
        // 실패해도(예: 얼굴이 이미 사라짐) 이 게이트만 통과시킨다, 다른 값은 이미 다 구했다.
        var qualityScore: Float? = nil, coverage: Float? = nil
        if scoreQuality {
            qualityScore = (try? await DetectFaceCaptureQualityRequest().perform(on: cg).first?.captureQuality?.score) ?? 1
            if let seg = try? await GeneratePersonSegmentationRequest().perform(on: cg) {
                // `box`(와 여기 들어오는 `point`)는 `toImageCoordinates(origin: .upperLeft)` 로 만든 좌상단 원점
                // 좌표다. 반면 `NormalizedPoint(imagePoint:in:)` 는 전달한 점을 그대로(flip 없이) x/width·y/height 로
                // 정규화하는데, `pixel(at:)`/`ImageProcessingRequest.regionOfInterest` 가 문서화한 Vision 규약은
                // **좌하단 원점**이다 — 즉 Y 를 미리 뒤집어 주지 않으면 세로축이 통째로 뒤집힌 위치를 샘플링하게 된다
                // (RunCodeSnippet 으로 실측 확인: 뒤집지 않으면 이미지 위쪽 점이 normalized y≈0.05 로 나와 Vision 의
                // "위쪽 = y 1" 규약과 반대). `brightness(_:in:)` 가 이미 같은 이유로 수동 flip 하는 것과 같은 패턴.
                coverage = PersonCoverage.ratio(faceBoxImageCoords: box) { point in
                    let flipped = CGPoint(x: point.x, y: CGFloat(size.height) - point.y)
                    return seg.pixel(at: NormalizedPoint(imagePoint: flipped, in: size))
                }
            } else {
                coverage = 1
            }
        }
        return PhotoFaceAnalysis(points: px(lm.allPoints), keyPoints: key, box: box, pose: pose, visionYawPitch: SIMD2(vy, vp),
                                 confidence: f.confidence, width: cg.width, height: cg.height, eyeAspectRatio: ear, mouthOpenRatio: mouthOpen,
                                 captureQualityScore: qualityScore, personCoverage: coverage,
                                 eyeAspectRatioLeft: earLeft, eyeAspectRatioRight: earRight, mouthWidthRatio: mouthWidthRatio,
                                 innerLipsAspect: innerLipsAspect, browRaiseLeft: browRaiseLeft, browRaiseRight: browRaiseRight, gazeX: gazeX, gazeY: gazeY)
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
        // 품질 점수·인물 매트는 throttle 로 건너뛴 프레임이면 nil — 직전 값을 그대로 들고 간다(처음이면 통과시키는 기본값 1).
        status = PhotoFrameStatus(isTracked: true, yaw: a.pose.x, pitch: a.pose.y, roll: a.pose.z, visionYaw: a.visionYawPitch.x, visionPitch: a.visionYawPitch.y,
                                  brightness: b, faceWidthRatio: Float(a.box.width) / Float(max(1, image.width)), landmarkCount: a.points.count,
                                  imageWidth: image.width, imageHeight: image.height, confidence: a.confidence,
                                  eyeAspectRatio: a.eyeAspectRatio, mouthOpenRatio: a.mouthOpenRatio,
                                  captureQualityScore: a.captureQualityScore ?? status.captureQualityScore, personCoverage: a.personCoverage ?? status.personCoverage,
                                  eyeAspectRatioLeft: a.eyeAspectRatioLeft, eyeAspectRatioRight: a.eyeAspectRatioRight, mouthWidthRatio: a.mouthWidthRatio,
                                  innerLipsAspect: a.innerLipsAspect, browRaiseLeft: a.browRaiseLeft, browRaiseRight: a.browRaiseRight, gazeX: a.gazeX, gazeY: a.gazeY)
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
        if kind == .eyesClosed, status.eyeAspectRatio > gate.eyesClosedMaxAspect { return (false, "눈을 감아 주세요") }
        if kind == .mouthOpen, status.mouthOpenRatio < gate.mouthOpenMinRatio { return (false, "입을 더 벌려 주세요") }
        if !gate.brightnessRange.contains(status.brightness) { return (false, status.brightness < gate.brightnessRange.lowerBound ? "조금 더 밝은 곳으로" : "너무 밝습니다") }
        // T-302: 캡처 품질 점수·인물 매트. `DetectFaceCaptureQualityRequest` 는 정면·선명도 기준이라 의도적으로
        // 고개를 돌리는 left·right·up 컷에서는 점수가 구조적으로 낮게 나온다 — "정면에서 찍어 주세요" 라는 문구와도
        // 모순되므로(이미 고개를 돌리라고 안내 중) 목표 각도가 정면(0,0)인 컷에만 적용한다.
        if ty == 0, tp == 0, status.captureQualityScore < gate.minCaptureQuality { return (false, "조금 더 선명하게, 정면에서 찍어 주세요") }
        if status.personCoverage < gate.minPersonCoverage { return (false, "얼굴이 배경과 잘 구분되지 않습니다") }
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

/// `interval` 프레임마다 한 번만 true — 비싼 Vision 요청(캡처 품질·인물 분할)의 실행 빈도를 줄인다.
final class FrameThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let interval: Int
    init(interval: Int) { self.interval = interval }
    func shouldRunExpensive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        count += 1
        guard count >= interval else { return false }
        count = 0
        return true
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
