//
//  FaceCaptureSession.swift
//  CoursonaCapture
//
//  iPhone ARFaceTracking 캡처 (TechPRD §6.3, T-201). M0 범위: 세션 수명 + 프레임 → `CaptureShot`(RGB·깊이·intrinsics·transform·1220 정점·52 가중치·조명)
//  + 8프레임 평균 + T-007 스파이크 프로브. 가이드 상태 기계·UI 는 M2.
//  🧪 실기기 필요: 시뮬레이터에는 TrueDepth/ARFaceTracking 이 없다(`ARFaceTrackingConfiguration.isSupported == false`).
//

import Foundation
import simd
import CoursonaCore
#if os(iOS)
import ARKit
import CoreImage
import Observation
import UIKit

/// T-007 스파이크 보고: 한 프레임에서 깊이·내부 파라미터·정점·조명이 동시에 나오는가.
public struct ARFaceProbeReport: Sendable, Equatable {
    public var vertexCount: Int
    public var triangleCount: Int
    public var triangleHash: String
    public var hasDepth: Bool
    public var depthWidth: Int
    public var depthHeight: Int
    public var depthFormat: String
    public var depthTimestampDelta: Double
    public var imageWidth: Int
    public var imageHeight: Int
    public var intrinsics: Geometry.Intrinsics
    public var hasDirectionalLight: Bool
    public var ambientIntensity: Float
    public var colorTemperature: Float
    public var primaryDirection: [Float]?
    public var blendShapeCount: Int

    public var summary: String {
        """
        ARKit 얼굴: 정점 \(vertexCount) (기대 1220) · 삼각형 \(triangleCount) · 해시 \(triangleHash)
        깊이: \(hasDepth ? "\(depthWidth)×\(depthHeight) \(depthFormat) (Δt \(String(format: "%.1f", depthTimestampDelta * 1000)) ms)" : "없음")
        이미지: \(imageWidth)×\(imageHeight) · fx \(Int(intrinsics.fx)) fy \(Int(intrinsics.fy)) cx \(Int(intrinsics.cx)) cy \(Int(intrinsics.cy))
        조명: \(hasDirectionalLight ? "방향 추정 있음" : "방향 추정 없음") · ambient \(Int(ambientIntensity)) lm · \(Int(colorTemperature)) K
        블렌드셰이프: \(blendShapeCount)개
        """
    }
}

/// 프레임 요약 (가이드 UI 용).
public struct FaceFrameStatus: Sendable, Equatable {
    public var isTracked = false
    public var yaw: Float = 0       // 도, + = 피사체 왼쪽으로 고개 돌림
    public var pitch: Float = 0     // 도, + = 위
    public var neutrality: Float = 0 // 52 가중치 합 (작을수록 중립)
    public var ambientLumens: Float = 0
    public var hasDepth = false
    /// 선택 컷 게이트(C3·F7): 눈 감기 평균(`eyeBlinkLeft`·`eyeBlinkRight` 평균) · 입 벌림(`jawOpen`).
    public var eyeBlinkAvg: Float = 0
    public var jawOpenWeight: Float = 0
}

/// 캡처 게이트 임계값 (M2 에서 DEBUG 패널로 노출).
public struct CaptureGate: Sendable, Equatable {
    /// 중립도 상한. 시선·깜빡임을 뺀 합 — `ArkitWeights.neutrality`. 고개를 돌리면 ARKit 이 볼·턱을 조금씩 올려 1 근처까지 간다(실측).
    /// 20차: 1.2 → 1.6 — "표정을 풀어 주세요"가 중립에 가까운데도 자주 떠 사용자 피드백으로 완화.
    public var neutralitySumMax: Float = 1.6
    /// 각도 허용치(도). 손으로 들고 맞추는 동작이라 1차의 ±6/±5 는 너무 좁았다(T-203 실기기) → ±9/±8 → 19차 ±14/±12 → 20차 ±20/±16.
    /// 피팅은 컷의 실제 자세(ARKit 변환)를 쓰므로 목표각에서 몇 도 벗어나도 품질 손실이 없고, 좌·우 30° 컷은 뺨·귀가 보이기만 하면 된다.
    /// 사용자 피드백: "링 중앙 원에 딱 닿고 가만있어야만 인정" — 허용치와 함께 유지 시간도 0.7 → 0.5 s, 순간 이탈은 `CaptureGuide` 유예로 흡수.
    public var yawTolerance: Float = 20
    public var pitchTolerance: Float = 16
    public var lumensRange: ClosedRange<Float> = 250...2000
    public var holdSeconds: Double = 0.5
    public var framesToAverage = 8
    /// 선택 컷(C3·F7) 임계값 — TechPRD §6.3: 눈 감기 `eyeBlinkLeft/Right ≥ 0.8`, 입 벌림 `jawOpen ≥ 0.5`. 20차: 완전히 감거나
    /// 크게 벌리지 않아도 인정되도록 완화(0.8→0.6 · 0.5→0.35).
    public var eyesClosedMinBlink: Float = 0.6
    public var mouthOpenMinJaw: Float = 0.35
    public init() {}
}

@MainActor
@Observable
public final class FaceCaptureSession: NSObject, ARSessionDelegate {
    public private(set) var status = FaceFrameStatus()
    /// 중립도에 가장 크게 기여하는 셰이프 (진단 시트에 표시 — 게이트가 막힐 때 원인을 바로 본다)
    public private(set) var topShapes: [(ArkitShape, Float)] = []
    public private(set) var probe: ARFaceProbeReport?
    public private(set) var errorText: String?
    public private(set) var isRunning = false
    public var gate = CaptureGate()
    /// 카메라 미리보기 (포트레이트 업라이트, 비반전, 절반 해상도). 뷰가 거울로 뒤집어 보여 준다.
    public private(set) var preview: CGImage?
    /// 미리보기 픽셀 좌표의 ARKit 얼굴 정점(8개 중 1개 서브샘플) — 와이어 오버레이용 (T-203)
    public private(set) var previewPoints: [SIMD2<Float>] = []

    private let session = ARSession()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// ARKit 델리게이트 큐 — 미리보기 CGImage 변환을 메인에서 하지 않기 위해
    private let delegateQueue = DispatchQueue(label: "coursona.face-capture", qos: .userInteractive)
    private let probeOnce = BusyFlag()
    private let previewBusy = BusyFlag()
    /// 평균용 링 버퍼 (최근 N 프레임의 정점·가중치)
    private var recentVertices: [[SIMD3<Float>]] = []
    private var recentWeights: [ArkitWeights] = []
    private var latestFrame: ARFrame?
    private var latestAnchor: ARFaceAnchor?
    /// 디버깅 체크(2026-10-08, 실기기 실측): `session(_:didUpdate:)` 가 들어오는 모든 프레임마다 무조건
    /// `Task { @MainActor in … }` 을 새로 만들어 `frame` 을 캡처해 두면, 메인 액터가 그 처리 속도를 못 따라갈 때
    /// (얼굴면 텍스처·에셋 부착처럼 메인 액터가 바쁠 때 특히) 아직 실행 안 된 Task 들이 각자 자기 `ARFrame` 을 쥔 채
    /// 쌓인다 — 실측으로 "ARSession 델리게이트가 ARFrame 11~12개를 쥐고 있다" 경고 + 카메라 픽셀 버퍼 풀 고갈로
    /// `CVPixelBufferCreate` 가 매번 실패하는 걸 직접 확인했다(Apple 문서가 말하는 "델리게이트의 스레딩·메모리 관리
    /// 문제"가 정확히 이것). 이미 있던 `previewBusy`/`probeOnce` 와 같은 패턴으로, 이전 프레임의 메인 액터 처리가
    /// 아직 안 끝났으면 이번 프레임은 조용히 버린다(ARKit 은 곧 다음 프레임을 또 보내 주므로 추적 품질에는 영향 없다).
    private let frameUpdateBusy = BusyFlag()
    /// 마지막으로 깊이 프레임을 본 시각. TrueDepth 깊이는 색 프레임과 주기가 달라 자주 nil 이라 "한동안 없음" 일 때만 경고한다.
    private var lastDepthSeen = Date.distantPast
    /// 최근 깊이 맵 (세로 회전 완료). 촬영 순간 프레임에 깊이가 없으면 이걸 쓴다.
    private var recentDepth: (map: DepthMap, at: Date)?
    /// 미리보기 축소 배율 (1920×1080 → 960×540 포트레이트 540×960)
    private static let previewScale: CGFloat = 0.5
    private static let previewVertexStride = 8

    public static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    public override init() { super.init() }

    public func start() {
        guard Self.isSupported else { errorText = "이 기기는 얼굴 추적(TrueDepth)을 지원하지 않습니다. 사진 폴백 캡처를 쓰세요."; return }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.maximumNumberOfTrackedFaces = 1
        session.delegate = self
        session.delegateQueue = delegateQueue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        // T-306: `UIDevice.orientation` 은 이 호출 전까지 항상 0(.unknown)을 돌려준다(문서에 명시) — 기록만 하는
        // 용도라도 꺼놓으면 전부 unknown 으로 남는다.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        isRunning = true
        errorText = nil
    }

    public func stop() {
        session.pause()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        isRunning = false
        recentVertices.removeAll(); recentWeights.removeAll()
        latestFrame = nil; latestAnchor = nil
        previewPoints = []
    }

    // MARK: ARSessionDelegate

    nonisolated public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let anchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first
        // 미리보기: 겹치지 않게(플래그) 포트레이트·절반 해상도 CGImage + 투영 정점. 얼굴이 없어도 영상은 보여 준다.
        var previewImage: CGImage? = nil
        var points: [SIMD2<Float>] = []
        if previewBusy.tryAcquire() {
            let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right).transformed(by: CGAffineTransform(scaleX: Self.previewScale, y: Self.previewScale))
            previewImage = ciContext.createCGImage(ci, from: ci.extent)
            if let anchor, let img = previewImage {
                let K = Self.portraitIntrinsics(frame: frame).scaled(toWidth: img.width, height: img.height)
                let camInv = Self.portraitCameraTransform(frame: frame).inverse
                let toCam = camInv * anchor.transform
                let verts = anchor.geometry.vertices
                points.reserveCapacity(verts.count / Self.previewVertexStride + 1)
                var i = 0
                while i < verts.count {
                    if let p = K.project(Geometry.transformPoint(toCam, verts[i])) { points.append(p) }
                    i += Self.previewVertexStride
                }
            }
            previewBusy.release()
        }
        guard let anchor else {
            Task { @MainActor in
                self.status.isTracked = false
                if let previewImage { self.preview = previewImage; self.previewPoints = [] }
            }
            return
        }
        let verts = anchor.geometry.vertices
        let weights = ArkitWeights(named: Dictionary(uniqueKeysWithValues: anchor.blendShapes.map { ($0.key.rawValue, $0.value.floatValue) }))
        // 얼굴 자세: **세로(포트레이트) 카메라 기준**.
        // `ARCamera.transform` 의 x 축은 기기 긴 축(전면 카메라 → 홈버튼)이라 세로로 들면 월드 아래를 향한다
        // (실측 (0, −0.999, −0.05), 문서와 일치). 그대로 쓰면 좌우 회전이 pitch 로 새어 나간다(실측 yaw −0.8° / pitch −33.8°).
        // 저장 메타의 `cameraTransform` 은 이미 이 회전이 적용된 값이므로, 번들을 다시 읽을 때는 **더 돌리지 않는다**.
        // 부호 규약(+yaw = 내 왼쪽)은 `FacePoseConvention` 이 맞춘다 — 실측에서 raw yaw 가 반대로 나온다.
        let faceInCam = Self.portraitCameraTransform(frame: frame).inverse * anchor.transform
        let (yaw, pitch) = FacePoseConvention.guideAngles(faceInPortraitCamera: faceInCam)
        let ambient = Float(frame.lightEstimate?.ambientIntensity ?? 0)
        let hasDepth = frame.capturedDepthData != nil
        // 깊이가 온 프레임에서만 변환해 캐시해 둔다(촬영 순간에는 대개 없다)
        let depthNow = hasDepth ? Self.convertDepth(frame.capturedDepthData) : nil
        // T-007 프로브는 첫 프레임 한 번만 (삼각형 해시 계산을 매 프레임 하지 않는다)
        let report: ARFaceProbeReport? = probeOnce.tryAcquire() ? Self.makeProbe(frame: frame, anchor: anchor) : nil
        guard frameUpdateBusy.tryAcquire() else { return }   // 이전 프레임이 메인 액터에서 아직 처리 중 — 이번 건 버린다(위 주석)
        Task { @MainActor in
            defer { self.frameUpdateBusy.release() }
            self.latestFrame = frame
            self.latestAnchor = anchor
            self.recentVertices.append(verts)
            self.recentWeights.append(weights)
            if self.recentVertices.count > self.gate.framesToAverage { self.recentVertices.removeFirst(); self.recentWeights.removeFirst() }
            if hasDepth { self.lastDepthSeen = Date() }
            if let depthNow { self.recentDepth = (depthNow, Date()) }
            self.status = FaceFrameStatus(isTracked: anchor.isTracked, yaw: yaw, pitch: pitch, neutrality: weights.neutrality, ambientLumens: ambient, hasDepth: hasDepth,
                                          eyeBlinkAvg: (weights[.eyeBlinkLeft] + weights[.eyeBlinkRight]) / 2, jawOpenWeight: weights[.jawOpen])
            self.topShapes = weights.topContributors()
            if let previewImage { self.preview = previewImage; self.previewPoints = points }
            if let report, self.probe == nil { self.probe = report }
        }
    }

    /// `AVDepthData` → 세로 회전된 `DepthMap`(Float32, m). 없으면 nil.
    nonisolated static func convertDepth(_ data: AVDepthData?) -> DepthMap? {
        guard let d = data else { return nil }
        let conv = d.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let pb = conv.depthDataMap
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let dw = CVPixelBufferGetWidth(pb), dh = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb) / 4
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: Float.self) else { return nil }
        // 가로 깊이 → 세로로 회전 (x' = dh−1−y, y' = x) — 저장 이미지·intrinsics 와 같은 방향
        var vals = [Float](repeating: 0, count: dw * dh)
        for y in 0..<dh { for x in 0..<dw { vals[x * dh + (dh - 1 - y)] = base[y * stride + x] } }
        return DepthMap(width: dh, height: dw, values: vals)
    }

    /// 가로 센서 → 세로(포트레이트) 저장 방향의 intrinsics. 규약·함정은 `Geometry.portraitRotated` 참고.
    nonisolated static func portraitIntrinsics(frame: ARFrame) -> Geometry.Intrinsics {
        let res = frame.camera.imageResolution
        return Geometry.portraitRotated(Geometry.Intrinsics(matrix: frame.camera.intrinsics, width: Int(res.width), height: Int(res.height)))
    }

    /// 같은 회전을 적용한 카메라 변환. intrinsics 와 **같은 방향**이어야 한다(T-203 실기기에서 어긋남을 확인).
    nonisolated static func portraitCameraTransform(frame: ARFrame) -> simd_float4x4 {
        frame.camera.transform * Geometry.portraitCameraRotation
    }

    nonisolated static func makeProbe(frame: ARFrame, anchor: ARFaceAnchor) -> ARFaceProbeReport {
        let geo = anchor.geometry
        let tris = geo.triangleIndices
        let hash = ARKitFaceTopology.hash(arkitTriangleIndices: tris)
        var dw = 0, dh = 0, fmt = "-"
        if let d = frame.capturedDepthData {
            dw = CVPixelBufferGetWidth(d.depthDataMap); dh = CVPixelBufferGetHeight(d.depthDataMap)
            let t = CVPixelBufferGetPixelFormatType(d.depthDataMap)
            fmt = t == kCVPixelFormatType_DepthFloat32 ? "DepthFloat32" : (t == kCVPixelFormatType_DepthFloat16 ? "DepthFloat16" : (t == kCVPixelFormatType_DisparityFloat32 ? "DisparityFloat32" : String(format: "%08x", t)))
        }
        let res = frame.camera.imageResolution
        let K = Geometry.Intrinsics(matrix: frame.camera.intrinsics, width: Int(res.width), height: Int(res.height))
        let dir = frame.lightEstimate as? ARDirectionalLightEstimate
        return ARFaceProbeReport(vertexCount: geo.vertices.count, triangleCount: tris.count / 3, triangleHash: ARKitFaceTopology.hexString(hash),
                                 hasDepth: frame.capturedDepthData != nil, depthWidth: dw, depthHeight: dh, depthFormat: fmt,
                                 depthTimestampDelta: frame.capturedDepthDataTimestamp > 0 ? frame.timestamp - frame.capturedDepthDataTimestamp : 0,
                                 imageWidth: Int(res.width), imageHeight: Int(res.height), intrinsics: K,
                                 hasDirectionalLight: dir != nil, ambientIntensity: Float(frame.lightEstimate?.ambientIntensity ?? 0),
                                 colorTemperature: Float(frame.lightEstimate?.ambientColorTemperature ?? 0),
                                 primaryDirection: dir.map { [$0.primaryLightDirection.x, $0.primaryLightDirection.y, $0.primaryLightDirection.z] },
                                 blendShapeCount: anchor.blendShapes.count)
    }

    // MARK: 촬영

    /// 최근 N 프레임 평균으로 한 컷을 만든다. 이미지는 **센서 방향 그대로** 가로 버퍼를 세로(포트레이트)로 돌려 저장하고 intrinsics 도 함께 돌린다.
    public func captureShot(kind: ShotKind) -> CaptureShot? {
        guard let frame = latestFrame, let anchor = latestAnchor, !recentVertices.isEmpty else { return nil }
        let n = recentVertices.count
        var avg = [SIMD3<Float>](repeating: .zero, count: recentVertices[0].count)
        for v in recentVertices { for i in avg.indices { avg[i] += v[i] } }
        for i in avg.indices { avg[i] /= Float(n) }
        var w = ArkitWeights()
        for r in recentWeights { w.add(r, scale: 1 / Float(n)) }

        // RGB: BGRA 로 렌더 후 90° 회전(포트레이트 업라이트, 전면 카메라는 좌우 반전하지 않음)
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let width = Int(ci.extent.width), height = Int(ci.extent.height)
        var image: RGBAImage? = nil
        if let cg = ciContext.createCGImage(ci, from: ci.extent) {
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            if ok { image = RGBAImage(width: width, height: height, bytes: buf) }
        }
        // 가로 → 세로 회전에 맞춘 intrinsics · 카메라 변환 (미리보기 투영과 같은 식)
        let intr = Self.portraitIntrinsics(frame: frame).scaled(toWidth: width, height: height)
        let camT = Self.portraitCameraTransform(frame: frame)

        // 깊이: 이 프레임에 있으면 그것, 없으면 **최근 캐시**(0.6 s 이내).
        // TrueDepth 깊이는 색 프레임과 주기가 달라 대부분의 프레임에 없다 — 1차 실기기 번들은 5컷 중 1컷만 깊이가 담겼다.
        var depth: DepthMap? = Self.convertDepth(frame.capturedDepthData)
        if depth == nil, let cached = recentDepth, Date().timeIntervalSince(cached.at) < 0.6 { depth = cached.map }
        let le = frame.lightEstimate
        let dir = le as? ARDirectionalLightEstimate
        let light = LightEstimate(ambientIntensity: Float(le?.ambientIntensity ?? 1000), ambientColorTemperature: Float(le?.ambientColorTemperature ?? 6500),
                                  primaryDirection: dir.map { [$0.primaryLightDirection.x, $0.primaryLightDirection.y, $0.primaryLightDirection.z] },
                                  primaryIntensity: dir.map { Float($0.primaryLightIntensity) })
        let meta = CaptureShotMeta(kind: kind, imageFile: "shot-\(kind.rawValue).jpg", depthFile: depth == nil ? nil : "depth-\(kind.rawValue).f32",
                                   imageWidth: width, imageHeight: height, depthWidth: depth?.width, depthHeight: depth?.height,
                                   intrinsics: intr, cameraTransform: camT, faceTransform: anchor.transform,
                                   faceVertices: avg, blendShapes: w, light: light, averagedFrames: n, timestamp: frame.timestamp,
                                   orientation: Self.captureOrientation(UIDevice.current.orientation))
        return CaptureShot(meta: meta, image: image, depth: depth)
    }

    /// T-306: 기록용 변환. 캡처·피팅 로직은 이 값을 쓰지 않는다 — 영상·깊이는 언제나 세로로 처리한다.
    nonisolated static func captureOrientation(_ ui: UIDeviceOrientation) -> CaptureOrientation {
        switch ui {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .faceUp: .faceUp
        case .faceDown: .faceDown
        default: .unknown
        }
    }

    /// 조도 경고 문장 (T-203 배너). 문제없으면 nil.
    public var lightWarning: String? {
        guard status.isTracked else { return nil }
        let lm = status.ambientLumens
        if lm < gate.lumensRange.lowerBound { return String(format: "너무 어둡습니다 (%.0f lm) — 밝은 곳으로", lm) }
        if lm > gate.lumensRange.upperBound { return String(format: "너무 밝습니다 (%.0f lm) — 역광을 피하세요", lm) }
        // 깊이는 색 프레임보다 느리게 와서 대부분의 프레임이 nil 이다 — 2초 넘게 없을 때만 경고
        if Date().timeIntervalSince(lastDepthSeen) > 2 { return "깊이 프레임이 2초 넘게 없습니다 — 얼굴을 30–60 cm 거리에" }
        return nil
    }

    /// 지금 프레임이 게이트를 통과하는가.
    public func passesGate(for kind: ShotKind) -> (ok: Bool, reason: String) {
        guard status.isTracked else { return (false, "얼굴을 찾는 중") }
        let (ty, tp) = kind.targetYawPitch
        if abs(status.yaw - ty) > gate.yawTolerance { return (false, status.yaw < ty ? "고개를 조금 더 왼쪽으로" : "고개를 조금 더 오른쪽으로") }
        if abs(status.pitch - tp) > gate.pitchTolerance { return (false, status.pitch < tp ? "턱을 조금 들어 주세요" : "턱을 조금 내려 주세요") }
        if kind.isNeutralRequired, status.neutrality > gate.neutralitySumMax { return (false, "표정을 풀어 주세요") }
        if kind == .eyesClosed, status.eyeBlinkAvg < gate.eyesClosedMinBlink { return (false, "눈을 감아 주세요") }
        if kind == .mouthOpen, status.jawOpenWeight < gate.mouthOpenMinJaw { return (false, "입을 더 벌려 주세요") }
        if !gate.lumensRange.contains(status.ambientLumens) { return (false, status.ambientLumens < gate.lumensRange.lowerBound ? "조금 더 밝은 곳으로" : "너무 밝습니다") }
        return (true, "유지하세요")
    }
}
#endif
