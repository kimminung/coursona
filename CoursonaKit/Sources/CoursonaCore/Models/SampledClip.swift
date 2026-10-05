//
//  SampledClip.swift
//  CoursonaCore
//
//  `clips/<name>.json` (Blender-요청.md §6): fps, frames, loop, bones{Neck,Head,Eye_L,Eye_R: [[qx,qy,qz,qw, px,py,pz] × frames]}, shapes{name: [w] × frames}.
//  2차 계약: 프레임 0…L 을 **끝 프레임 포함**해 굽는다 → frames = L+1, 길이 = (frames−1)/fps. 루프 클립은 첫 = 끝 프레임.
//  뼈 값은 **흉상(USD) 공간**에서 그 뼈의 레스트 피벗(머리 위치)을 기준으로 한 회전(사원수 xyzw)·이동(m) — 부모 뼈 회전은 포함하지 않는다.
//  앱은 Neck → Head → Eye 순으로 합성한다: T_bone(p) = P + R·(p − P) + t.
//

import Foundation
import simd

public struct BonePose: Sendable, Equatable {
    public var rotation: simd_quatf
    public var position: SIMD3<Float>
    public init(rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: SIMD3<Float> = .zero) { self.rotation = rotation; self.position = position }
    public static let identity = BonePose()
    public func interpolated(to other: BonePose, _ t: Float) -> BonePose {
        BonePose(rotation: simd_slerp(rotation, other.rotation, t), position: position + (other.position - position) * t)
    }
}

public struct SampledClip: Codable, Sendable, Equatable {
    public var name: String
    public var fps: Float
    public var frames: Int
    public var loop: Bool
    /// 뼈 이름 → 프레임별 [qx,qy,qz,qw,px,py,pz]
    public var bones: [String: [[Float]]]
    /// 셰이프 이름 → 프레임별 가중치
    public var shapes: [String: [Float]]

    public init(name: String, fps: Float = 30, frames: Int, loop: Bool, bones: [String: [[Float]]] = [:], shapes: [String: [Float]] = [:]) {
        self.name = name; self.fps = fps; self.frames = frames; self.loop = loop; self.bones = bones; self.shapes = shapes
    }

    /// 길이(초) = (frames − 1) / fps (끝 프레임 포함 샘플 규약).
    public var duration: Float { Float(max(1, frames - 1)) / fps }

    /// 시간 t(초) 의 52 가중치 (선형 보간, 루프 처리).
    public func weights(at t: Float) -> ArkitWeights {
        guard frames > 0 else { return .zero }
        let (i0, i1, f) = frameIndices(at: t)
        var w = ArkitWeights()
        for (name, track) in shapes {
            guard let shape = ArkitShape(rawValue: name), track.count == frames else { continue }
            w[shape] = track[i0] + (track[i1] - track[i0]) * f
        }
        return w
    }

    /// 시간 t 의 뼈 포즈.
    public func bonePose(_ bone: BoneName, at t: Float) -> BonePose? {
        guard let track = bones[bone.rawValue], track.count == frames, frames > 0 else { return nil }
        let (i0, i1, f) = frameIndices(at: t)
        func pose(_ a: [Float]) -> BonePose {
            guard a.count >= 7 else { return .identity }
            return BonePose(rotation: simd_quatf(ix: a[0], iy: a[1], iz: a[2], r: a[3]), position: SIMD3(a[4], a[5], a[6]))
        }
        return pose(track[i0]).interpolated(to: pose(track[i1]), f)
    }

    /// 루프 클립은 첫/끝 프레임이 같아야 한다 (검증기).
    public func loopSeamError() -> Float {
        guard loop, frames >= 2 else { return 0 }
        var e: Float = 0
        for (_, t) in shapes where t.count == frames { e = max(e, abs(t[0] - t[frames - 1])) }
        for (_, t) in bones where t.count == frames {
            for k in 0..<min(t[0].count, t[frames - 1].count) { e = max(e, abs(t[0][k] - t[frames - 1][k])) }
        }
        return e
    }

    private func frameIndices(at t: Float) -> (Int, Int, Float) {
        let dur = duration
        var time = t
        if loop { time = dur > 0 ? time.truncatingRemainder(dividingBy: dur) : 0; if time < 0 { time += dur } }
        else { time = max(0, min(dur, time)) }
        let fpos = time * fps
        let i0 = min(frames - 1, max(0, Int(fpos.rounded(.down))))
        let i1 = min(frames - 1, i0 + 1)   // 루프는 첫 = 끝 프레임이라 같은 식
        return (i0, i1, fpos - Float(i0))
    }

    /// 계약 클립 목록 (이름, 길이 s, 루프).
    public static let contract: [(name: String, seconds: Float, loop: Bool)] = [
        ("idle_breathe", 4, true), ("listen", 3, true), ("nod", 1, false),
        ("talk_a", 2, true), ("talk_b", 2, true), ("talk_c", 2, true),
        ("laugh", 1.5, false), ("surprise", 1, false), ("bow", 1.5, false), ("think", 3, true), ("blink_set", 2, true),
    ]
}
