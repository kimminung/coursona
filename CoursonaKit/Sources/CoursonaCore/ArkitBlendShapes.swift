//
//  ArkitBlendShapes.swift
//  CoursonaCore
//
//  소반 8차 `FaceRig/ArkitBlendShapes.swift` 이식 (2026-10-03). 소반 리포는 수정하지 않았다.
//  초상에서는 ARKit 52 가 **유일한 표정 표준**이다(TechPRD §2). 레거시 13개 이름 어댑터는
//  소반 1차 USDZ 를 임시 템플릿으로 돌릴 때만 쓰인다.
//

import Foundation
import simd

/// ARKit `ARFaceAnchor.BlendShapeLocation` 과 같은 52개 이름 (rawValue 가 그대로 ARKit 이름).
public enum ArkitShape: String, CaseIterable, Codable, Sendable {
    // 눈 (14)
    case eyeBlinkLeft, eyeLookDownLeft, eyeLookInLeft, eyeLookOutLeft, eyeLookUpLeft, eyeSquintLeft, eyeWideLeft
    case eyeBlinkRight, eyeLookDownRight, eyeLookInRight, eyeLookOutRight, eyeLookUpRight, eyeSquintRight, eyeWideRight
    // 턱 (4)
    case jawForward, jawLeft, jawRight, jawOpen
    // 입 (23)
    case mouthClose, mouthFunnel, mouthPucker, mouthLeft, mouthRight
    case mouthSmileLeft, mouthSmileRight, mouthFrownLeft, mouthFrownRight
    case mouthDimpleLeft, mouthDimpleRight, mouthStretchLeft, mouthStretchRight
    case mouthRollLower, mouthRollUpper, mouthShrugLower, mouthShrugUpper
    case mouthPressLeft, mouthPressRight, mouthLowerDownLeft, mouthLowerDownRight, mouthUpperUpLeft, mouthUpperUpRight
    // 눈썹 (5)
    case browDownLeft, browDownRight, browInnerUp, browOuterUpLeft, browOuterUpRight
    // 볼·코·혀 (6)
    case cheekPuff, cheekSquintLeft, cheekSquintRight, noseSneerLeft, noseSneerRight, tongueOut

    public var index: Int { Self.indexByCase[self]! }
    private static let indexByCase: [ArkitShape: Int] = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
    public static let count = allCases.count   // 52

    /// ARKit 이름 어느 표기든 받는다: 우리 rawValue(`mouthSmileLeft`) **또는 `ARFaceAnchor.BlendShapeLocation.rawValue`(`mouthSmile_L`)**.
    /// ARKit 의 실제 문자열은 좌우 셰이프 28개가 `_L`/`_R` 접미사다 — rawValue 로만 받던 M2 캡처는 이 28개를 **조용히 0 으로** 저장했다
    /// (실기기 번들: 깜빡임·미소까지 전부 0, `mouthShrug`·`jawOpen` 같은 비대칭 셰이프만 남음). M3 에서 발견·수정.
    public init?(arkitName: String) {
        if let s = ArkitShape(rawValue: arkitName) { self = s; return }
        if arkitName.hasSuffix("_L"), let s = ArkitShape(rawValue: String(arkitName.dropLast(2)) + "Left") { self = s; return }
        if arkitName.hasSuffix("_R"), let s = ArkitShape(rawValue: String(arkitName.dropLast(2)) + "Right") { self = s; return }
        return nil
    }
    /// `ARFaceAnchor.BlendShapeLocation` 표기: 좌우 쌍 36개는 `_L`/`_R`, 단 `jawLeft/jawRight/mouthLeft/mouthRight`(턱·입 **방향**)는 ARKit 도 그대로 쓴다.
    public var arkitLocationName: String {
        switch self {
        case .jawLeft, .jawRight, .mouthLeft, .mouthRight: return rawValue
        default:
            if rawValue.hasSuffix("Left") { return String(rawValue.dropLast(4)) + "_L" }
            if rawValue.hasSuffix("Right") { return String(rawValue.dropLast(5)) + "_R" }
            return rawValue
        }
    }

    /// 립싱크 최소 세트 (Blender-요청.md §2).
    public static let lipSyncMinimum: [ArkitShape] = [.jawOpen, .mouthClose, .mouthFunnel, .mouthPucker, .mouthStretchLeft, .mouthStretchRight,
                                                      .mouthLowerDownLeft, .mouthLowerDownRight, .mouthPressLeft, .mouthPressRight,
                                                      .mouthSmileLeft, .mouthSmileRight, .mouthUpperUpLeft, .mouthUpperUpRight]
    /// 눈·눈썹 필수 세트 (Blender-요청.md §2).
    public static let eyeBrowMinimum: [ArkitShape] = [.eyeBlinkLeft, .eyeBlinkRight, .eyeWideLeft, .eyeWideRight, .eyeSquintLeft, .eyeSquintRight,
                                                      .browInnerUp, .browDownLeft, .browDownRight, .browOuterUpLeft, .browOuterUpRight]

    /// 입 영역 셰이프 (레이어 합성에서 비셈/라이브 표정이 치환하는 범위).
    public var isMouthRegion: Bool { rawValue.hasPrefix("mouth") || rawValue.hasPrefix("jaw") || self == .tongueOut || self == .cheekPuff }
    /// 눈 영역 셰이프.
    public var isEyeRegion: Bool { rawValue.hasPrefix("eye") }
    /// 시선 셰이프 8개(`eyeLookIn/Out/Up/Down` × 좌우) — 표정이 아니라 **눈동자 방향**이라 중립도에서 뺀다.
    public var isGaze: Bool { rawValue.hasPrefix("eyeLook") }
    /// 눈 깜빡임 2개 — 순간적이라 중립도에서 뺀다.
    public var isBlink: Bool { self == .eyeBlinkLeft || self == .eyeBlinkRight }
    /// 눈썹 영역 셰이프.
    public var isBrowRegion: Bool { rawValue.hasPrefix("brow") }
    /// 왼쪽/오른쪽 짝 (대칭 검사·미러용). 없으면 자기 자신.
    public var mirrored: ArkitShape {
        if rawValue.hasSuffix("Left") { return ArkitShape(rawValue: String(rawValue.dropLast(4)) + "Right") ?? self }
        if rawValue.hasSuffix("Right") { return ArkitShape(rawValue: String(rawValue.dropLast(5)) + "Left") ?? self }
        if self == .jawLeft { return .jawRight }
        if self == .jawRight { return .jawLeft }
        if self == .mouthLeft { return .mouthRight }
        if self == .mouthRight { return .mouthLeft }
        return self
    }
}

/// 52개 가중치 (0…1). 값 타입이라 네트워크/컴포넌트/클립 프레임에 그대로 들어간다.
public struct ArkitWeights: Hashable, Sendable, Codable {
    public var values: [Float]

    public init() { values = [Float](repeating: 0, count: ArkitShape.count) }
    public init(_ dict: [ArkitShape: Float]) {
        self.init()
        for (k, v) in dict { values[k.index] = v }
    }
    /// ARKit 이름 문자열 사전에서 (ARFaceAnchor.blendShapes, 클립 JSON 등). `mouthSmileLeft` 와 `mouthSmile_L` 둘 다 받는다.
    public init(named dict: [String: Float]) {
        self.init()
        for (name, v) in dict { if let s = ArkitShape(arkitName: name) { values[s.index] = v } }
    }
    /// 52개 배열에서 (길이가 다르면 앞에서부터 채우고 나머지는 0).
    public init(values: [Float]) {
        self.init()
        for i in 0..<min(values.count, ArkitShape.count) { self.values[i] = values[i] }
    }

    public static let zero = ArkitWeights()

    public subscript(_ shape: ArkitShape) -> Float {
        get { values[shape.index] }
        set { values[shape.index] = newValue }
    }

    /// 누적 (최대 1).
    public mutating func add(_ shape: ArkitShape, _ v: Float) { values[shape.index] = min(1, values[shape.index] + v) }
    public mutating func add(_ other: ArkitWeights, scale: Float = 1) {
        for i in values.indices { values[i] = min(1, values[i] + other.values[i] * scale) }
    }
    public mutating func scale(_ s: Float) { for i in values.indices { values[i] *= s } }
    public mutating func clamp() { for i in values.indices { values[i] = min(1, max(0, values[i])) } }

    /// ARKit 이름 → 값 (0 은 생략).
    public var named: [String: Float] {
        var out: [String: Float] = [:]
        for s in ArkitShape.allCases where values[s.index] > 0.0005 { out[s.rawValue] = values[s.index] }
        return out
    }

    /// 선형 보간.
    public func blended(toward target: ArkitWeights, _ t: Float) -> ArkitWeights {
        var out = self
        for i in values.indices { out.values[i] += (target.values[i] - values[i]) * t }
        return out
    }

    /// 가중치 합.
    public var sum: Float { values.reduce(0, +) }

    /// 캡처 가이드의 "표정 중립도". **시선 8개(`eyeLook*`)와 눈 깜빡임 2개(`eyeBlink*`)는 뺀다** —
    /// 좌·우·위 컷은 고개를 돌린 채 카메라를 보므로 눈이 반대로 돌아가 `eyeLookIn/Out/Up/Down` 이 1.0 까지 올라가고,
    /// 깜빡임은 순간적이라 "표정을 풀었는가" 와 무관하다. 둘을 넣으면 세 각도 컷이 영영 게이트를 통과하지 못한다(T-203 실기기).
    public var neutrality: Float {
        var s: Float = 0
        for shape in ArkitShape.allCases where !shape.isGaze && !shape.isBlink { s += self[shape] }
        return s
    }

    /// 중립도에 가장 크게 기여하는 셰이프 (진단용).
    public func topContributors(_ n: Int = 3) -> [(ArkitShape, Float)] {
        ArkitShape.allCases
            .filter { !$0.isGaze && !$0.isBlink && self[$0] > 0.05 }
            .map { ($0, self[$0]) }
            .sorted { $0.1 > $1.1 }
            .prefix(n)
            .map { $0 }
    }
    public var isEmpty: Bool { !values.contains { $0 > 0.0005 } }
}

/// 입 모양(비셈). 한글 중성에서 유도한다 (`HangulViseme`).
public enum Viseme: String, CaseIterable, Sendable, Codable {
    case rest, A, I, U, E, O, press

    /// 레거시 USDZ 셰이프키 이름(A/I/U/E/O/Press)에 직접 주는 가중치. ARKit 52 에셋에서는 쓰지 않는다.
    public var legacyWeights: [String: Float] {
        switch self {
        case .rest:  return [:]
        case .A:     return ["A": 1.0]
        case .I:     return ["I": 1.0]
        case .U:     return ["U": 1.0]
        case .E:     return ["E": 1.0]
        case .O:     return ["O": 1.0]
        case .press: return ["Press": 1.0]
        }
    }
}

/// 비셈 → ARKit 조합 프리셋 (소반 8차 값; 블렌더 재합성 오차 보정 포함).
public enum ArkitVisemePreset {
    public static func weights(for viseme: Viseme, amount: Float) -> ArkitWeights {
        var w = ArkitWeights()
        let a = max(0, min(1, amount))
        switch viseme {
        case .rest:
            break
        case .A:    // 아: 턱 크게, 아랫입술 내림 (+ 윗입술 올림 0.3)
            w[.jawOpen] = 0.6 * a; w[.mouthLowerDownLeft] = 0.3 * a; w[.mouthLowerDownRight] = 0.3 * a
            w[.mouthUpperUpLeft] = 0.3 * a; w[.mouthUpperUpRight] = 0.3 * a
        case .I:    // 이: 옆으로 당김, 턱 조금
            w[.jawOpen] = 0.15 * a; w[.mouthStretchLeft] = 0.5 * a; w[.mouthStretchRight] = 0.5 * a
            w[.mouthSmileLeft] = 0.2 * a; w[.mouthSmileRight] = 0.2 * a
        case .U:    // 우: 오므림
            w[.mouthPucker] = 0.8 * a; w[.mouthFunnel] = 0.3 * a; w[.jawOpen] = 0.1 * a
        case .E:    // 에
            w[.jawOpen] = 0.4 * a; w[.mouthStretchLeft] = 0.4 * a; w[.mouthStretchRight] = 0.4 * a
        case .O:    // 오/어
            w[.jawOpen] = 0.35 * a; w[.mouthFunnel] = 0.7 * a; w[.mouthPucker] = 0.3 * a
        case .press: // ㅁ/ㅂ/ㅍ 폐쇄
            w[.mouthPressLeft] = 0.8 * a; w[.mouthPressRight] = 0.8 * a; w[.mouthClose] = 0.6 * a
        }
        return w
    }
}

/// ARKit 가중치를 **메시가 실제로 가진 셰이프키 이름**으로 바꾼다 (레거시 소반 1차 USDZ 호환).
public enum ShapeNameAdapter {
    public static let legacyNames: Set<String> = ["Blink_L", "Blink_R", "EyeWide", "Squint", "BrowUp", "JawOpen", "A", "I", "U", "E", "O", "Smile", "Press"]

    /// 메시 이름 집합이 ARKit 이름을 포함하는가 (하나라도 있으면 ARKit 에셋으로 본다).
    public static func usesArkitNames(_ names: Set<String>) -> Bool {
        names.contains("jawOpen") || names.contains("eyeBlinkLeft") || names.contains("mouthSmileLeft")
    }

    public static func resolve(_ arkit: ArkitWeights, legacyVisemes: [String: Float], names: Set<String>) -> [String: Float] {
        if usesArkitNames(names) { return arkit.named }
        return legacy(from: arkit, visemes: legacyVisemes)
    }

    /// ARKit → 레거시 13개. 좌우 분리 셰이프는 max 로 합친다.
    public static func legacy(from w: ArkitWeights, visemes: [String: Float]) -> [String: Float] {
        var out: [String: Float] = [:]
        func put(_ k: String, _ v: Float) { if v > 0.0005 { out[k, default: 0] = min(1, out[k, default: 0] + v) } }
        put("Blink_L", w[.eyeBlinkLeft])
        put("Blink_R", w[.eyeBlinkRight])
        put("EyeWide", max(w[.eyeWideLeft], w[.eyeWideRight]))
        put("Squint", max(w[.eyeSquintLeft], w[.eyeSquintRight]))
        put("BrowUp", max(w[.browInnerUp], w[.browOuterUpLeft], w[.browOuterUpRight]))
        put("Smile", max(w[.mouthSmileLeft], w[.mouthSmileRight]))
        put("Press", max(w[.mouthPressLeft], w[.mouthPressRight], w[.mouthClose]))
        if visemes.isEmpty {
            put("JawOpen", w[.jawOpen])
            put("U", w[.mouthPucker])
            put("O", w[.mouthFunnel] * (1 - w[.mouthPucker]))
            put("I", max(w[.mouthStretchLeft], w[.mouthStretchRight]) * (1 - w[.jawOpen]))
            put("A", max(w[.mouthLowerDownLeft], w[.mouthLowerDownRight]) * w[.jawOpen])
        } else {
            for (k, v) in visemes { put(k, v) }
            put("JawOpen", w[.jawOpen] * 0.4)
        }
        return out
    }
}
