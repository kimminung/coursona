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

import Foundation
import CoursonaCore
import CoursonaRig

@MainActor
public final class FaceDriverCoordinator {
    #if os(iOS)
    public let arkit = ARKitFaceDriver()
    #endif
    public let vision = VisionFaceDriver()
    public let mic = MicVisemeDriver()
    public private(set) var activeSource = "없음"

    public init() {}

    public func start() {
        #if os(iOS)
        if ARKitFaceDriver.isSupported { arkit.start() } else { vision.session.start() }
        #else
        vision.session.start()
        #endif
        Task { await mic.start() }
    }

    public func stop() {
        #if os(iOS)
        arkit.stop()
        #endif
        vision.stop()
        mic.stop()
    }

    /// 매 프레임: 지금 쓸 수 있는 가장 좋은 입력을 골라 `rig` 를 채우고, 머리 자세가 있으면 `bust` 에도 적용한다.
    public func tick(rig: inout FaceRigComponent, bust: BustEntity?, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        #if os(iOS)
        if arkit.isTracking {
            rig.externalWeights = arkit.weights
            rig.externalIncludesBlink = true
            rig.audioLevel = 0
            activeSource = "ARKit"
            if let bust, let pose = arkit.headPose { bust.applyHeadPose(pose) }
            return
        }
        #endif
        vision.tick(now: now)
        if vision.isTracking, !vision.isCalibrating {
            rig.externalWeights = vision.weights
            rig.externalIncludesBlink = true
            rig.audioLevel = 0
            activeSource = "Vision"
            return
        }
        // 얼굴을 못 잡거나(또는 중립 캘리브레이션 중) — 마이크 음량만으로 FaceRigSystem 의 기존 합성에 맡긴다.
        rig.externalWeights = nil
        rig.audioLevel = mic.level
        activeSource = vision.isTracking ? "Vision 캘리브레이션 중(마이크로 대체)" : "마이크만(얼굴 없음)"
    }
}
