//
//  MicVisemeDriver.swift
//  CoursonaDrive
//
//  C6(T-603) 마이크 보완 경로. `MicLevelMeter`(음량)·`HangulViseme`(텍스트 → 비셈 타임라인) 를 한데 묶는다.
//  "Vision 이 입을 못 잡을 때 보완" 은 `FaceRigComponent.externalWeights == nil` 일 때 `FaceRigSystem` 이
//  이미 가진 오디오 기반 턱·비셈 합성(`FaceRig.swift`)이 자동으로 담당한다 — 이 타입은 그 입력(`audioLevel`)을
//  채우는 역할만 한다. 새 합성 로직을 또 만들지 않는다(`FaceDriverCoordinator` 가 우선순위를 정한다).
//

import Foundation
import CoursonaCore
import CoursonaCapture

@MainActor
public final class MicVisemeDriver {
    public let mic = MicLevelMeter()
    public var level: Float { mic.level }
    public var isRunning: Bool { mic.isRunning }

    public init() {}

    public func start() async { await mic.start() }
    public func stop() { mic.stop() }

    /// 텍스트(자막·TTS 스크립트 등)로 비셈 타임라인을 만든다 — `FaceRigComponent.visemeQueue` 에 그대로 넣으면 된다.
    public static func visemes(for text: String, secondsPerSyllable: Float = 0.16) -> [VisemeStep] {
        HangulViseme.visemes(for: text, secondsPerSyllable: secondsPerSyllable)
    }
}
