//
//  HangulViseme.swift
//  CoursonaCore
//
//  소반 `FaceRig.swift` 의 HangulViseme 이식. 한글 음절의 중성(모음)으로 입모양을, 초성/받침 ㅁ·ㅂ·ㅍ 으로 입술 폐쇄를 만든다.
//

import Foundation

public struct VisemeStep: Sendable, Equatable {
    public var viseme: Viseme
    public var duration: Float
    public init(_ viseme: Viseme, _ duration: Float) { self.viseme = viseme; self.duration = duration }
}

public enum HangulViseme {
    /// 문장 → 비셈 큐. `secondsPerSyllable` 는 TTS 속도에 맞춘다(기본 0.16 s).
    public static func visemes(for text: String, secondsPerSyllable: Float = 0.16) -> [VisemeStep] {
        var out: [VisemeStep] = []
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0xAC00 && v <= 0xD7A3 {
                let idx = Int(v - 0xAC00)
                let initial = idx / (21 * 28)
                let medial = (idx % (21 * 28)) / 28
                let final = idx % 28
                // 초성 ㅁ(6) ㅂ(7) ㅃ(8) ㅍ(17) → 모음 앞에 짧은 입술 폐쇄(약 70 ms)
                if [6, 7, 8, 17].contains(initial) {
                    let press = min(0.07, secondsPerSyllable * 0.35)
                    out.append(VisemeStep(.press, press))
                    out.append(VisemeStep(viseme(medial: medial), max(0.04, secondsPerSyllable - press)))
                } else {
                    out.append(VisemeStep(viseme(medial: medial), secondsPerSyllable))
                }
                // 받침 ㅁ(16) ㅂ(17) ㅍ(26) → 입술 닫기
                if [16, 17, 26].contains(final) { out.append(VisemeStep(.press, secondsPerSyllable * 0.4)) }
            } else if scalar.properties.isWhitespace || ",.!?".unicodeScalars.contains(scalar) {
                out.append(VisemeStep(.rest, secondsPerSyllable * 0.8))
            }
        }
        return out
    }

    /// 중성 인덱스(0…20) → 비셈.
    public static func viseme(medial: Int) -> Viseme {
        switch medial {
        case 0, 2, 9, 10:           return .A   // ㅏ ㅑ ㅘ ㅙ
        case 1, 3, 5, 7, 11, 15:    return .E   // ㅐ ㅒ ㅔ ㅖ ㅚ ㅞ
        case 4, 6, 14:              return .O   // ㅓ ㅕ ㅝ
        case 8, 12:                 return .O   // ㅗ ㅛ
        case 13, 16, 17:            return .U   // ㅜ ㅟ ㅠ
        case 18, 19, 20:            return .I   // ㅡ ㅢ ㅣ
        default:                    return .A
        }
    }

    /// 전체 길이(초).
    public static func duration(of steps: [VisemeStep]) -> Float { steps.reduce(0) { $0 + $1.duration } }
}

/// 마이크 버퍼 → 0...1 음량 (AVAudioEngine 탭 등에서 사용). 소반 `AudioLevel` 이식.
public enum AudioLevel {
    public static func normalizedRMS(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))          // -120 ... 0 dB
        return min(1, max(0, (db + 50) / 40))          // -50dB → 0, -10dB → 1
    }
}
