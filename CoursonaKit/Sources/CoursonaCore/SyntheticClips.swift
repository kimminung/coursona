//
//  SyntheticClips.swift
//  CoursonaCore
//
//  블렌더 프리비즈 클립이 오기 전까지 ClipPlayer·레이어 합성을 돌리기 위한 **절차적 클립**. 계약 목록(SampledClip.contract)과 같은
//  이름·길이·루프 규칙을 지키므로 검증기 테스트에도 쓴다. 블렌더 클립이 들어오면 교체된다.
//

import Foundation
import simd

public enum SyntheticClips {
    public static func all() -> [SampledClip] { SampledClip.contract.map { make($0.name) } }

    public static func make(_ name: String) -> SampledClip {
        guard let spec = SampledClip.contract.first(where: { $0.name == name }) else {
            return SampledClip(name: name, frames: 30, loop: false)
        }
        let fps: Float = 30
        let frames = Int((spec.seconds * fps).rounded()) + 1   // 끝 프레임 포함 (2차 계약)
        var shapes: [String: [Float]] = [:]
        var bones: [String: [[Float]]] = [:]
        func track(_ s: ArkitShape, _ f: (Float) -> Float) {   // t: 0…1
            shapes[s.rawValue] = (0..<frames).map { f(Float($0) / Float(max(1, frames - 1))) }
        }
        func bone(_ b: BoneName, _ f: (Float) -> BonePose) {
            bones[b.rawValue] = (0..<frames).map { i in
                let p = f(Float(i) / Float(max(1, frames - 1)))
                return [p.rotation.imag.x, p.rotation.imag.y, p.rotation.imag.z, p.rotation.real, p.position.x, p.position.y, p.position.z]
            }
        }
        func rot(pitch: Float = 0, yaw: Float = 0, roll: Float = 0) -> simd_quatf {
            simd_quatf(angle: pitch * .pi / 180, axis: [1, 0, 0]) * simd_quatf(angle: yaw * .pi / 180, axis: [0, 1, 0]) * simd_quatf(angle: roll * .pi / 180, axis: [0, 0, 1])
        }
        // 루프 클립은 sin(2π t) 계열(첫·끝 프레임 동일), 1회 클립은 0 에서 시작해 0 으로 복귀
        func pulse(_ t: Float) -> Float { sin(.pi * t) }                 // 0→1→0
        func loopWave(_ t: Float, _ k: Float = 1) -> Float { sin(2 * .pi * k * t) } // 첫=끝=0
        func blink(_ t: Float, at c: Float, width: Float = 0.08) -> Float { let d = abs(t - c) / width; return d < 1 ? (1 - d) : 0 }

        switch name {
        case "idle_breathe":
            bone(.Neck) { t in BonePose(rotation: rot(pitch: 1.2 * loopWave(t)), position: SIMD3(0, 0.002 * loopWave(t), 0)) }
            bone(.Head) { t in BonePose(rotation: rot(yaw: 1.0 * loopWave(t, 1), roll: 0.5 * loopWave(t, 1))) }
            track(.eyeBlinkLeft) { t in max(blink(t, at: 0.25), blink(t, at: 0.75)) }
            track(.eyeBlinkRight) { t in max(blink(t, at: 0.25), blink(t, at: 0.75)) }
        case "listen":
            bone(.Head) { t in BonePose(rotation: rot(pitch: 3 * pulse(t) * (t > 0.5 ? loopWave(t, 2) : 0), yaw: 6 * sin(.pi * t), roll: 4 * sin(.pi * t))) }
            track(.browInnerUp) { t in 0.25 * pulse(t) }
            track(.eyeBlinkLeft) { t in blink(t, at: 0.6) }
            track(.eyeBlinkRight) { t in blink(t, at: 0.6) }
        case "nod":
            bone(.Head) { t in BonePose(rotation: rot(pitch: 10 * abs(sin(2 * .pi * t)))) }
        case "talk_a", "talk_b", "talk_c":
            let k: Float = name == "talk_a" ? 1 : (name == "talk_b" ? 2 : 1.5)
            bone(.Head) { t in BonePose(rotation: rot(pitch: 2 * loopWave(t, k), yaw: 3 * loopWave(t, 1), roll: 1.5 * loopWave(t, k))) }
            track(.browInnerUp) { t in 0.2 * max(0, loopWave(t, k)) }
            track(.browOuterUpLeft) { t in 0.15 * max(0, loopWave(t, 1)) }
            track(.browOuterUpRight) { t in 0.15 * max(0, loopWave(t, 1)) }
        case "laugh":
            bone(.Neck) { t in BonePose(rotation: rot(pitch: -8 * pulse(t))) }
            bone(.Head) { t in BonePose(rotation: rot(pitch: -6 * pulse(t))) }
            track(.mouthSmileLeft) { t in 0.9 * pulse(t) }
            track(.mouthSmileRight) { t in 0.9 * pulse(t) }
            track(.jawOpen) { t in 0.45 * pulse(t) * (0.7 + 0.3 * abs(sin(6 * .pi * t))) }
            track(.eyeBlinkLeft) { t in 0.7 * pulse(t) }
            track(.eyeBlinkRight) { t in 0.7 * pulse(t) }
            track(.cheekSquintLeft) { t in 0.6 * pulse(t) }
            track(.cheekSquintRight) { t in 0.6 * pulse(t) }
        case "surprise":
            bone(.Head) { t in BonePose(rotation: rot(pitch: -3 * pulse(t))) }
            track(.eyeWideLeft) { t in 0.9 * pulse(t) }
            track(.eyeWideRight) { t in 0.9 * pulse(t) }
            track(.browInnerUp) { t in 0.9 * pulse(t) }
            track(.browOuterUpLeft) { t in 0.7 * pulse(t) }
            track(.browOuterUpRight) { t in 0.7 * pulse(t) }
            track(.jawOpen) { t in 0.3 * pulse(t) }
        case "bow":
            let hold: (Float) -> Float = { t in t < 0.3 ? t / 0.3 : (t < 0.6 ? 1 : max(0, 1 - (t - 0.6) / 0.4)) }
            bone(.Neck) { t in BonePose(rotation: rot(pitch: 12 * hold(t))) }
            bone(.Head) { t in BonePose(rotation: rot(pitch: 13 * hold(t))) }
            track(.eyeLookDownLeft) { t in 0.8 * hold(t) }
            track(.eyeLookDownRight) { t in 0.8 * hold(t) }
            bone(.Eye_L) { t in BonePose(rotation: rot(pitch: 15 * hold(t))) }
            bone(.Eye_R) { t in BonePose(rotation: rot(pitch: 15 * hold(t))) }
        case "think":
            bone(.Head) { t in BonePose(rotation: rot(pitch: -3 * pulse(t), yaw: 8 * sin(.pi * t), roll: -5 * sin(.pi * t))) }
            bone(.Eye_L) { t in BonePose(rotation: rot(pitch: -12 * pulse(t), yaw: 10 * pulse(t))) }
            bone(.Eye_R) { t in BonePose(rotation: rot(pitch: -12 * pulse(t), yaw: 10 * pulse(t))) }
            track(.eyeLookUpLeft) { t in 0.7 * pulse(t) }
            track(.eyeLookUpRight) { t in 0.7 * pulse(t) }
            track(.eyeLookOutLeft) { t in 0.5 * pulse(t) }
            track(.eyeLookInRight) { t in 0.5 * pulse(t) }
            track(.browDownLeft) { t in 0.5 * pulse(t) }
            track(.mouthPressLeft) { t in 0.5 * pulse(t) }
            track(.mouthPressRight) { t in 0.5 * pulse(t) }
        case "blink_set":
            track(.eyeBlinkLeft) { t in max(blink(t, at: 0.3), blink(t, at: 0.42)) }
            track(.eyeBlinkRight) { t in max(blink(t, at: 0.3), blink(t, at: 0.42)) }
        default: break
        }
        if spec.loop {
            // 루프 클립 보장: 끝 프레임 = 첫 프레임
            for (k, v) in shapes where !v.isEmpty { var vv = v; vv[frames - 1] = vv[0]; shapes[k] = vv }
            for (k, v) in bones where !v.isEmpty { var vv = v; vv[frames - 1] = vv[0]; bones[k] = vv }
        }
        return SampledClip(name: name, fps: fps, frames: frames, loop: spec.loop, bones: bones, shapes: shapes)
    }
}

private extension BoneName {
    static let Neck = BoneName.neck
    static let Head = BoneName.head
    static let Eye_L = BoneName.eyeL
    static let Eye_R = BoneName.eyeR
}
