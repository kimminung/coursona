//
//  ClipPlayer.swift
//  CoursonaRig
//
//  `SampledClip` 재생: 보간·루프·크로스페이드(기본 250 ms) (T-504 기본). 뼈 트랙은 T-006 결정에 따라
//  **자체 샘플러**(이 클래스)로 돌린다 — 이유는 Docs/Spikes.md T-006 참고. AnimationGraphResource 는 USD SkelAnimation 이 들어오는 M5 에서 재검토.
//

import Foundation
import simd
import CoursonaCore

@MainActor
public final class ClipPlayer {
    public private(set) var current: SampledClip?
    private var previous: SampledClip?
    private var time: Float = 0
    private var previousTime: Float = 0
    private var fade: Float = 0
    private var fadeDuration: Float = 0.25
    public private(set) var isFinished = false
    public var speed: Float = 1

    public struct Pose: Sendable {
        public var weights: ArkitWeights
        public var bones: [BoneName: BonePose]
        public static let empty = Pose(weights: .zero, bones: [:])
    }

    public init() {}

    public func play(_ clip: SampledClip, crossfade: Float = 0.25) {
        if let cur = current { previous = cur; previousTime = time; fade = 0; fadeDuration = max(0.001, crossfade) } else { previous = nil }
        current = clip
        time = 0
        isFinished = false
    }

    public func stop() { previous = current; previousTime = time; fade = 0; current = nil; isFinished = true }

    /// dt 만큼 진행하고 현재 포즈를 돌려준다.
    @discardableResult
    public func advance(_ dt: Float) -> Pose {
        time += dt * speed
        previousTime += dt * speed
        if fade < 1 { fade = min(1, fade + dt / fadeDuration) }
        guard let clip = current else { return previous.map { sample($0, previousTime) } ?? .empty }
        if !clip.loop, time >= clip.duration { time = clip.duration; isFinished = true }
        var pose = sample(clip, time)
        if let prev = previous, fade < 1 {
            let p = sample(prev, previousTime)
            pose.weights = p.weights.blended(toward: pose.weights, fade)
            for b in BoneName.allCases {
                switch (p.bones[b], pose.bones[b]) {
                case let (a?, c?): pose.bones[b] = a.interpolated(to: c, fade)
                case let (a?, nil): pose.bones[b] = a.interpolated(to: .identity, fade)
                case let (nil, c?): pose.bones[b] = BonePose.identity.interpolated(to: c, fade)
                default: break
                }
            }
        } else { previous = nil }
        return pose
    }

    public var progress: Float { guard let c = current, c.duration > 0 else { return 0 }; return c.loop ? (time.truncatingRemainder(dividingBy: c.duration)) / c.duration : min(1, time / c.duration) }
    public var frameIndex: Int { guard let c = current else { return 0 }; return Int(progress * Float(max(1, c.frames - 1))) }

    private func sample(_ clip: SampledClip, _ t: Float) -> Pose {
        var bones: [BoneName: BonePose] = [:]
        for b in BoneName.allCases { if let p = clip.bonePose(b, at: t) { bones[b] = p } }
        return Pose(weights: clip.weights(at: t), bones: bones)
    }
}
