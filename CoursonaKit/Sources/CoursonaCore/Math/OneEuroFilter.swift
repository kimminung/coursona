//
//  OneEuroFilter.swift
//  CoursonaCore
//
//  1€ 필터(Casiez et al. 2012) — C6(T-602) `VisionFaceDriver` 입력 떨림 억제. 느린 움직임은 세게,
//  빠른 움직임은 약하게 스무딩해 "느린 지연"과 "빠른 떨림" 사이 통상 트레이드오프를 완화한다.
//  순수 수학(상태 = 이전 값 2개)이라 `CoursonaCore` 에 둔다 — Foundation/simd 만.
//

import Foundation

public struct OneEuroFilter: Sendable {
    /// 느린 움직임일 때 컷오프(작을수록 더 부드럽지만 더 느리게 따라간다).
    public var minCutoff: Float
    /// 속도에 비례해 컷오프를 올리는 정도(클수록 빠른 움직임에서 지연이 덜하지만 떨림이 더 보인다).
    public var beta: Float
    /// 속도 추정 자체에 쓰는 컷오프.
    public var dCutoff: Float
    private var xPrev: Float?
    private var dxPrev: Float = 0
    private var tPrev: Float?

    public init(minCutoff: Float = 1.0, beta: Float = 0.0, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * max(1e-6, cutoff))
        return 1 / (1 + tau / dt)
    }

    /// `timestamp` 는 단조 증가하는 초 단위 시각(예: `CACurrentMediaTime()`). 첫 호출은 그대로 통과시킨다.
    public mutating func filter(_ x: Float, timestamp t: Float) -> Float {
        guard let tp = tPrev, let xp = xPrev else {
            tPrev = t; xPrev = x; dxPrev = 0
            return x
        }
        let dt = max(1e-6, t - tp)
        let dx = (x - xp) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        let dxHat = aD * dx + (1 - aD) * dxPrev
        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff: cutoff, dt: dt)
        let xHat = a * x + (1 - a) * xp
        tPrev = t; xPrev = xHat; dxPrev = dxHat
        return xHat
    }

    /// 상태 초기화(추적이 끊겼다 다시 시작할 때 — 끊긴 동안의 시간차로 생기는 스파이크 방지).
    public mutating func reset() {
        xPrev = nil; dxPrev = 0; tPrev = nil
    }
}
