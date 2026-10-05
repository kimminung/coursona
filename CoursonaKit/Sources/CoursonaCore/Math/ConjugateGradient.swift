//
//  ConjugateGradient.swift
//  CoursonaCore
//
//  대칭 양정치 희소계용 예조건 공액기울기(PCG). 행렬은 **연산자 클로저**로 받는다(라플라시안처럼 명시적으로 만들 필요가 없는 경우).
//  실루엣 맞춤(T-304)의 가우스-뉴턴 단계가 쓴다: 미지수 = 정점당 변위 float3, 수천 개. 밀집 풀이(DenseSolver)는 400 을 넘기면 느리다.
//  내적은 Double 로 누적해 결정적·안정적이다.
//

import Foundation
import simd

public enum ConjugateGradient {
    public struct Result: Sendable {
        public var x: [SIMD3<Float>]
        public var iterations: Int
        /// 최종 |r| / |b|
        public var relativeResidual: Double
    }

    /// A x = b. `apply(x)` 는 A·x. `diagonal` 은 야코비 예조건(성분별 대각, nil 이면 없음). `x0` 초기값.
    public static func solve(b: [SIMD3<Float>], x0: [SIMD3<Float>]? = nil, diagonal: [SIMD3<Float>]? = nil,
                             maxIterations: Int = 200, tolerance: Double = 1e-6,
                             apply: ([SIMD3<Float>]) -> [SIMD3<Float>]) -> Result {
        let n = b.count
        func dot(_ a: [SIMD3<Float>], _ c: [SIMD3<Float>]) -> Double {
            var s = 0.0
            for i in 0..<n { s += Double(simd_dot(a[i], c[i])) }
            return s
        }
        func precondition(_ r: [SIMD3<Float>]) -> [SIMD3<Float>] {
            guard let d = diagonal, d.count == n else { return r }
            var z = r
            for i in 0..<n {
                z[i] = SIMD3(r[i].x / max(1e-12, d[i].x), r[i].y / max(1e-12, d[i].y), r[i].z / max(1e-12, d[i].z))
            }
            return z
        }
        var x = x0 ?? [SIMD3<Float>](repeating: .zero, count: n)
        var r = b
        if x0 != nil {
            let ax = apply(x)
            for i in 0..<n { r[i] -= ax[i] }
        }
        let bnorm = max(1e-30, dot(b, b).squareRoot())
        var z = precondition(r)
        var p = z
        var rz = dot(r, z)
        var it = 0
        var rnorm = dot(r, r).squareRoot()
        while it < maxIterations, rnorm / bnorm > tolerance {
            let ap = apply(p)
            let pap = dot(p, ap)
            guard pap > 1e-30 else { break }
            let alpha = Float(rz / pap)
            for i in 0..<n { x[i] += p[i] * alpha; r[i] -= ap[i] * alpha }
            rnorm = dot(r, r).squareRoot()
            z = precondition(r)
            let rzNew = dot(r, z)
            let beta = Float(rzNew / max(1e-30, rz))
            rz = rzNew
            for i in 0..<n { p[i] = z[i] + p[i] * beta }
            it += 1
        }
        return Result(x: x, iterations: it, relativeResidual: rnorm / bnorm)
    }
}
