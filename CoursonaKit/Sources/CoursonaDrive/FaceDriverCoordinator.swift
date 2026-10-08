//
//  FaceDriverCoordinator.swift
//  CoursonaDrive
//
//  C6(T-601·T-602·T-603 배선) 우선순위 합성: ARKit(iOS, 있으면 최상) > Vision(얼굴 추적 중, 캘리브레이션 끝남)
//  > 마이크만(둘 다 못 잡을 때 — `FaceRigComponent.externalWeights = nil` 로 두면 `FaceRigSystem` 의 기존
//  오디오 기반 턱·비셈 합성이 그대로 입을 채운다). 소반 `CompanionRootView.MouthSourceKind` 의 우선순위
//  폴백(faceTracking > cameraLips > microphone)과 같은 모양 — 새 타입으로 재정리했을 뿐 합성 자체는
//  `FaceRigSystem`(이미 포팅됨)에 맡긴다.
//
//  거울 화면(UXPRD 화면 6, T-808)이 쓰는 상태 — `source`(배지 문구), `isCalibrating`·`calibrationProgress`(캘리브레이션
//  오버레이), `preview`(PiP), 카메라/마이크 켜고 끄기, 기준 자세 재설정, 캘리브레이션 건너뛰기 — 를 여기서 한 번에 낸다.
//

import Foundation
import CoreGraphics
import simd
import CoursonaCore
import CoursonaRig

@MainActor
public final class FaceDriverCoordinator {
    /// 지금 흉상을 움직이는 입력.
    public enum Source: Equatable, Sendable {
        case none
        case arkit
        case vision
        case visionCalibrating
        case micOnly
        /// 배지에 그대로 쓰는 한 줄.
        public var label: String {
            switch self {
            case .none: "입력 없음"
            case .arkit: "Face ID 표정 52개"
            case .vision: "카메라 표정 12개 + 마이크 입모양"
            case .visionCalibrating: "기준 자세 보정 중"
            case .micOnly: "마이크 입모양만(얼굴 못 찾음)"
            }
        }
    }

    #if os(iOS)
    public let arkit = ARKitFaceDriver()
    #endif
    public let vision = VisionFaceDriver()
    public let mic = MicVisemeDriver()
    public private(set) var source: Source = .none
    /// 옛 호출자용 문자열(= `source.label`).
    public var activeSource: String { source.label }
    public private(set) var cameraEnabled = false
    public private(set) var micEnabled = false

    public init() {}

    /// 이 기기에서 ARKit(TrueDepth) 경로를 쓰는가 — 아니면 Vision(일반 카메라) 경로.
    public var usesARKit: Bool {
        #if os(iOS)
        return ARKitFaceDriver.isSupported
        #else
        return false
        #endif
    }

    /// 중립 캘리브레이션 중(Vision 경로만 — ARKit 은 캘리브레이션이 없다).
    public var isCalibrating: Bool { !usesARKit && cameraEnabled && vision.isCalibrating }
    public var calibrationProgress: Double { vision.calibrationProgress }
    /// 얼굴을 잡고 있는가(어느 경로든).
    public var isTracking: Bool {
        #if os(iOS)
        if usesARKit { return arkit.isTracking }
        #endif
        return vision.isTracking
    }
    /// PiP 용 카메라 프레임 — Vision 경로만(ARKit 드라이버는 자체 ARSession 이라 프레임을 안 내보낸다).
    public var preview: CGImage? { usesARKit ? nil : vision.session.preview }
    /// PiP 위에 찍을 얼굴 랜드마크(정규화 0…1, Vision 경로만).
    public var previewPoints: [SIMD2<Float>] { usesARKit ? [] : vision.session.previewLandmarks }

    public func start() {
        setCamera(true)
        setMic(true)
    }

    public func stop() {
        setCamera(false)
        setMic(false)
        source = .none
    }

    public func setCamera(_ on: Bool) {
        guard on != cameraEnabled else { return }
        cameraEnabled = on
        #if os(iOS)
        if usesARKit { on ? arkit.start() : arkit.stop(); return }
        #endif
        on ? vision.start() : vision.stop()
    }

    public func setMic(_ on: Bool) {
        guard on != micEnabled else { return }
        micEnabled = on
        if on { Task { await mic.start() } } else { mic.stop() }
    }

    /// "기준 자세 재설정" — Vision 경로는 2초 중립 캘리브레이션을 다시, ARKit 은 할 게 없다(절대 가중치).
    public func recalibrate() {
        guard !usesARKit else { return }
        vision.recalibrate()
    }

    /// "건너뛰고 바로 거울 보기".
    public func skipCalibration() { vision.skipCalibration() }

    /// 매 프레임: 지금 쓸 수 있는 가장 좋은 입력을 골라 `rig` 를 채우고, 머리 자세가 있으면 `bust` 에도 적용한다.
    public func tick(rig: inout FaceRigComponent, bust: BustEntity?, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        let level = micEnabled ? mic.level : 0
        #if os(iOS)
        if usesARKit, cameraEnabled, arkit.isTracking {
            rig.externalWeights = arkit.weights
            rig.externalIncludesBlink = true
            rig.audioLevel = 0
            source = .arkit
            if let bust, let pose = arkit.headPose { bust.applyHeadPose(pose) }
            return
        }
        #endif
        if cameraEnabled, !usesARKit {
            vision.tick(now: now)
            if vision.isTracking, !vision.isCalibrating {
                rig.externalWeights = vision.weights
                rig.externalIncludesBlink = true
                // Vision 은 입 모양 신호가 성기다(12 셰이프) — 마이크 음량은 FaceRigSystem 이 입에 더해 쓰도록 남긴다.
                rig.audioLevel = level
                source = .vision
                // 🧪 머리 자세: `ARKitFaceDriver` 와 같은 축·부호 규약(yaw + = 피사체 왼쪽, pitch + = 위, 도 단위)으로 합성한다 —
                // Vision 각도 부호는 실기기에서 아직 확인 못 했다(`PhotoFrameStatus.visionYaw` 주석 참고).
                if let bust {
                    let q = simd_quatf(angle: vision.pitch * .pi / 180, axis: [1, 0, 0]) * simd_quatf(angle: vision.yaw * .pi / 180, axis: [0, 1, 0])
                    bust.applyHeadPose(BonePose(rotation: q))
                }
                return
            }
        }
        // 얼굴을 못 잡거나(또는 중립 캘리브레이션 중) — 마이크 음량만으로 FaceRigSystem 의 기존 합성에 맡긴다.
        rig.externalWeights = nil
        rig.audioLevel = level
        if !cameraEnabled { source = micEnabled ? .micOnly : .none }
        else if !usesARKit, vision.isTracking, vision.isCalibrating { source = .visionCalibrating }
        else { source = micEnabled ? .micOnly : .none }
        bust?.applyHeadPose(nil)
    }
}
