//
//  SpeechGuide.swift
//  CoursonaCapture
//
//  캡처 중 한국어 안내 음성 (T-203 선택 기능). 같은 문장을 연달아 읽지 않고, 꺼져 있으면 아무 것도 하지 않는다.
//  마이크가 아니라 스피커만 쓴다 — 권한 불필요.
//

import Foundation
#if os(iOS) || os(macOS)
import AVFoundation

@MainActor
public final class SpeechGuide {
    /// 기본 꺼짐 (조용한 촬영이 기본, 사용자가 진단 시트에서 켠다).
    public var isEnabled = false {
        didSet { if !isEnabled { stop() } }
    }
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    private let synth = AVSpeechSynthesizer()
    private var lastSpoken = ""
    private var lastSpokenAt = Date.distantPast
    /// 같은 문장을 다시 읽기까지의 최소 간격 (초)
    public var repeatInterval: TimeInterval = 3.5

    public init() {}

    /// 문장을 읽는다. 꺼져 있거나, 같은 문장을 방금 읽었으면 무시.
    public func say(_ text: String, interrupt: Bool = false) {
        guard isEnabled, !text.isEmpty else { return }
        let now = Date()
        if text == lastSpoken, now.timeIntervalSince(lastSpokenAt) < repeatInterval { return }
        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        else if synth.isSpeaking { return }   // 말하는 중에는 겹치지 않게
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        u.rate = rate
        synth.speak(u)
        lastSpoken = text
        lastSpokenAt = now
    }

    /// 상태가 바뀌었으니 같은 문장이라도 다시 읽어도 된다 (스텝 전환 등).
    public func resetRepeatGuard() { lastSpoken = "" }

    public func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        lastSpoken = ""
    }
}
#endif
