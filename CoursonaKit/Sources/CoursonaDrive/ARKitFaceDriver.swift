//
//  ARKitFaceDriver.swift
//  CoursonaDrive
//
//  C6(T-601) iOS·iPadOS(Face ID) 라이브 구동. `FaceCaptureSession`(A 등급 캡처, `CoursonaCapture`)과 같은
//  ARSession/ARFaceAnchor → `ArkitWeights` 변환(`ArkitWeights(named:)`)과 자세 규약(`FacePoseConvention`)을
//  그대로 재사용한다 — 캡처는 게이트를 통과한 정지 컷 한 장을 모으지만, 이 드라이버는 매 프레임 그대로 흘려보낸다.
//
//  🧪 머리 자세(`headPose`)는 yaw·pitch 만 쓴다(`FacePoseConvention` 이 roll 을 아예 다루지 않는다 — 기존 규약과
//  동일 범위). 각도 → 쿼터니언 합성 축·순서는 라이브 구동에서 **처음** 쓰는 것이라 실기기 없이는 맞는지 확인할
//  방법이 없다(T-306 에서 비슷한 회전 수학을 실기기 없이 건드려 버그가 난 전례 — 가장 조심해야 할 부분). 표정
//  가중치(`weights`)는 `FaceCaptureSession` 이 이미 실기기로 검증한 변환을 그대로 쓰므로 신뢰도가 더 높다.
//

#if os(iOS)
import ARKit
import Foundation
import simd
import CoursonaCore
import CoursonaCapture

@MainActor
public final class ARKitFaceDriver: NSObject, ARSessionDelegate {
    public static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    public private(set) var weights = ArkitWeights()
    /// 머리 자세 근사(🧪 위 머리말 참고). 추적이 안 되면 nil.
    public private(set) var headPose: BonePose?
    public private(set) var isTracking = false

    private let session = ARSession()

    public override init() {
        super.init()
        session.delegate = self
    }

    public func start() {
        guard Self.isSupported else { return }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    public func stop() {
        session.pause()
        isTracking = false
    }

    public nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let anchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, anchor.isTracked else {
            Task { @MainActor in self.isTracking = false }
            return
        }
        let w = ArkitWeights(named: Dictionary(uniqueKeysWithValues: anchor.blendShapes.map { ($0.key.rawValue, $0.value.floatValue) }))
        let portraitCameraTransform = frame.camera.transform * Geometry.portraitCameraRotation
        let faceInCam = portraitCameraTransform.inverse * anchor.transform
        let (yaw, pitch) = FacePoseConvention.guideAngles(faceInPortraitCamera: faceInCam)
        let pose = BonePose(rotation: simd_quatf(angle: pitch * .pi / 180, axis: [1, 0, 0]) * simd_quatf(angle: yaw * .pi / 180, axis: [0, 1, 0]))
        Task { @MainActor in
            self.weights = w
            self.headPose = pose
            self.isTracking = true
        }
    }

    public nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.isTracking = false }
    }
}
#endif
