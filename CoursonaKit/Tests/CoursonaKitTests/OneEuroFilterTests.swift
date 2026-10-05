import Testing
@testable import CoursonaCore

@Suite("1€ 필터 (C6, T-602)")
struct OneEuroFilterTests {
    @Test("일정한 값이 들어오면 그대로 수렴한다")
    func constantSignalConverges() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.0)
        var last: Float = 0
        for i in 0..<30 { last = f.filter(5.0, timestamp: Float(i) * (1.0 / 60)) }
        #expect(abs(last - 5.0) < 0.001)
    }

    @Test("노이즈 섞인 신호는 원 신호보다 분산이 줄어든다")
    func smoothsNoise() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.0)
        let base: [Float] = (0..<60).map { _ in 1.0 }
        var noisy: [Float] = []
        var rng = SystemRandomNumberGenerator()
        for i in base.indices { noisy.append(base[i] + Float.random(in: -0.3...0.3, using: &rng)) }
        var filtered: [Float] = []
        for (i, x) in noisy.enumerated() { filtered.append(f.filter(x, timestamp: Float(i) * (1.0 / 60))) }
        func variance(_ xs: [Float]) -> Float {
            let m = xs.reduce(0, +) / Float(xs.count)
            return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(xs.count)
        }
        // 초반 수렴 구간은 빼고 비교(필터는 과거 없을 때 원값을 그대로 통과시키므로).
        #expect(variance(Array(filtered.suffix(30))) < variance(Array(noisy.suffix(30))))
    }

    @Test("beta 가 크면 빠른 움직임을 더 빨리 따라간다(지연이 준다)")
    func higherBetaReducesLagOnFastMotion() {
        var lowBeta = OneEuroFilter(minCutoff: 0.3, beta: 0.0)
        var highBeta = OneEuroFilter(minCutoff: 0.3, beta: 2.0)
        // 0 에 머물다 1 로 뛰는 계단 입력 — 뛴 직후 한 프레임의 반응을 비교.
        for i in 0..<5 {
            let t = Float(i) * (1.0 / 60)
            _ = lowBeta.filter(0, timestamp: t)
            _ = highBeta.filter(0, timestamp: t)
        }
        let tStep = Float(5) * (1.0 / 60)
        let lowOut = lowBeta.filter(1.0, timestamp: tStep)
        let highOut = highBeta.filter(1.0, timestamp: tStep)
        #expect(highOut > lowOut)
    }

    @Test("reset 후에는 다시 첫 값을 그대로 통과시킨다")
    func resetClearsState() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.0)
        _ = f.filter(1.0, timestamp: 0)
        _ = f.filter(1.0, timestamp: 1.0 / 60)
        f.reset()
        let afterReset = f.filter(9.0, timestamp: 10) // 임의의 새 타임스탬프(끊겼다 재시작 가정)
        #expect(afterReset == 9.0)
    }
}
