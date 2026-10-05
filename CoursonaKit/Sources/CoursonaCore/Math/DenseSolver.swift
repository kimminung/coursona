//
//  DenseSolver.swift
//  CoursonaCore
//
//  작은 밀집 선형계(≤ ~400) 전용 가우스 소거(부분 피벗). Accelerate 없이 순수 Swift — 플랫폼 독립·결정적.
//  RBF(≈300 중심 + 4) 와 TPS(≤ 80 점) 가 쓴다. 조건수 추정은 피벗 최소/최대 비로 근사한다.
//

import Foundation

public enum DenseSolver {
    public struct Solution: Sendable {
        /// n × k (row-major)
        public var x: [Double]
        /// |최대 피벗| / |최소 피벗| — 조건수의 거친 하한. 1e12 를 넘으면 정규화 λ 를 넣는다.
        public var pivotRatio: Double
    }

    /// A(n×n, row-major) X = B(n×k, row-major). 특이 행렬이면 nil.
    public static func solve(_ A: [Double], _ B: [Double], n: Int, k: Int) -> Solution? {
        precondition(A.count == n * n && B.count == n * k)
        var a = A, b = B
        var maxPivot = 0.0, minPivot = Double.greatestFiniteMagnitude
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col * n + col])
            var r = col + 1
            while r < n {
                let v = abs(a[r * n + col])
                if v > best { best = v; pivot = r }
                r += 1
            }
            guard best > 1e-14 else { return nil }
            maxPivot = max(maxPivot, best); minPivot = min(minPivot, best)
            if pivot != col {
                for c in 0..<n { a.swapAt(col * n + c, pivot * n + c) }
                for c in 0..<k { b.swapAt(col * k + c, pivot * k + c) }
            }
            let d = a[col * n + col]
            r = col + 1
            while r < n {
                let f = a[r * n + col] / d
                if f != 0 {
                    for c in col..<n { a[r * n + c] -= f * a[col * n + c] }
                    for c in 0..<k { b[r * k + c] -= f * b[col * k + c] }
                }
                r += 1
            }
        }
        var x = b
        var col = n - 1
        while col >= 0 {
            for c in 0..<k {
                var s = x[col * k + c]
                var j = col + 1
                while j < n { s -= a[col * n + j] * x[j * k + c]; j += 1 }
                x[col * k + c] = s / a[col * n + col]
            }
            col -= 1
        }
        return Solution(x: x, pivotRatio: maxPivot / max(minPivot, 1e-300))
    }

    /// 단일 우변.
    public static func solve(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
        solve(A, b, n: n, k: 1)?.x
    }
}
