import Testing
import Foundation
@testable import CoursonaCore
@testable import CoursonaCapture

/// T-202 가이드 상태 기계.
@Suite("캡처 가이드 (T-202)")
struct CaptureGuideTests {
    @Test("게이트를 0.7 s 유지하면 한 번만 촬영 신호, 흔들리면 타이머 리셋 (유예 0)")
    func holdTimer() {
        var g = CaptureGuide(holdSeconds: 0.7, graceSeconds: 0)
        // #expect 매크로 안에서는 mutating 호출을 못 하므로 결과를 먼저 받는다
        func tick(_ ok: Bool, _ t: Double) -> Bool { g.update(gateOK: ok, now: t) }
        #expect(g.current == .front)
        let a = tick(true, 10.0); #expect(!a)
        let b = tick(true, 10.5); #expect(!b)
        #expect(abs(g.holdProgress - 0.5 / 0.7) < 1e-9)
        let c = tick(false, 10.6); #expect(!c)             // 흔들림 → 리셋
        #expect(g.holdProgress == 0)
        let d = tick(true, 11.0); #expect(!d)
        let e = tick(true, 11.7); #expect(e)               // 0.7 s 유지 → 촬영
        #expect(g.holdProgress == 0)
        let f = tick(true, 11.75); #expect(!f)             // 리셋 후 다시 시작
    }

    @Test("유예: 유지 중 게이트가 잠깐 빠져도 타이머가 살아 있고, 유예를 넘기면 리셋한다")
    func graceKeepsTimer() {
        var g = CaptureGuide(holdSeconds: 0.5, graceSeconds: 0.35)
        func tick(_ ok: Bool, _ t: Double) -> Bool { g.update(gateOK: ok, now: t) }
        _ = tick(true, 10.0)
        _ = tick(true, 10.2)
        #expect(abs(g.holdProgress - 0.4) < 1e-9)
        let a = tick(false, 10.3); #expect(!a)             // 0.1 s 이탈 — 유예 안: 진행률 유지, 신호 없음
        #expect(abs(g.holdProgress - 0.4) < 1e-9 && g.holdStart == 10.0)
        let b = tick(false, 10.4); #expect(!b)             // 0.2 s 이탈 — 아직 유예 안
        let c = tick(true, 10.5); #expect(c)               // 돌아오자마자 0.5 s 경과 → 촬영 (이탈 틱에서는 절대 안 찍는다)
        #expect(g.holdProgress == 0)
        // 유예를 넘기면 리셋
        _ = tick(true, 20.0)
        _ = tick(true, 20.2)
        _ = tick(false, 20.3)
        let d = tick(false, 20.7); #expect(!d)             // 마지막 통과(20.2)에서 0.5 s → 유예(0.35) 초과 → 리셋
        #expect(g.holdProgress == 0 && g.holdStart == nil)
        let e = tick(true, 20.8); #expect(!e)              // 처음부터 다시
        #expect(g.holdStart == 20.8)
    }

    @Test("촬영 → 다음 스텝, 건너뛰기, 재촬영, 완료")
    func flow() {
        // 필수 5스텝만 — eyesClosed/mouthOpen(선택) 은 isOptional 게이팅/스킵이 UI 쪽 책임이라 여기선 다루지 않는다.
        var g = CaptureGuide(steps: [.front, .left, .right, .up, .smile])
        g.markCaptured(.front)
        #expect(g.current == .left && g.state(of: .front) == .captured && g.completedCount == 1)
        g.skip()                                           // 왼쪽 건너뜀
        #expect(g.current == .right && g.state(of: .left) == .skipped)
        g.markCaptured(.right); g.markCaptured(.up); g.markCaptured(.smile)
        #expect(g.isComplete && g.current == nil)
        let fired = g.update(gateOK: true, now: 1)
        #expect(!fired)                                    // 완료 상태에서는 신호 없음
        g.retake(.left)                                    // 건너뛴 컷으로 돌아감
        #expect(g.current == .left && !g.isComplete && g.state(of: .left) == .current)
        g.markCaptured(.left)
        #expect(g.isComplete && g.completedCount == 5)
        g.retake(.front)
        #expect(g.current == .front && g.completedCount == 4)
        g.reset()
        #expect(g.current == .front && g.completedCount == 0 && g.state(of: .left) == .pending)
    }

    @Test("중간 컷을 다시 찍으면 이후 미촬영 컷으로 이어진다")
    func retakeThenContinue() {
        var g = CaptureGuide()
        g.markCaptured(.front); g.markCaptured(.left)
        g.retake(.front)
        g.markCaptured(.front)
        #expect(g.current == .right)                       // left 는 이미 있음 → right 로
    }
}
