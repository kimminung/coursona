//
//  ThinPlateSpline.swift
//  CoursonaCore
//
//  소반 7차 `Persona/TemplateFit.swift` 의 ThinPlateSpline 이식(2D). 초상에서는 **희소 폴백**(Vision 76점 ↔ template.json
//  랜드마크, TechPRD §6.3 폴백·T-306) 과 UV 공간 보정에 쓴다. 3D 밀집 전파는 `BiharmonicRBF` 가 담당한다.
//

import Foundation
import simd

/// 2D 박판 스플라인. 커널 U(r) = r² log r², 정규화 λ 를 K 대각에 더한다.
public struct ThinPlateSpline: Sendable {
    public let sources: [SIMD2<Float>]
    public let weights: [SIMD2<Float>]
    /// 아핀 부분 [a0, a1, a2] (x,y 각각)
    public let affine: [SIMD2<Float>]
    public let pivotRatio: Double

    /// - Parameters:
    ///   - source: 원본 점, target: 대응점 (같은 개수, ≥ 3개, 일직선 아님)
    ///   - lambda: 평활 정규화 (좌표² 단위). 0 이면 보간, 클수록 아핀에 가까움.
    public init?(source: [SIMD2<Float>], target: [SIMD2<Float>], lambda: Float = 0.002) {
        let n = source.count
        guard n >= 3, target.count == n else { return nil }
        let m = n + 3
        var L = [Double](repeating: 0, count: m * m)
        func kernel(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Double {
            let r2 = Double(simd_length_squared(a - b))
            return r2 > 1e-12 ? r2 * log(r2) : 0
        }
        for i in 0..<n {
            for j in 0..<n {
                L[i * m + j] = kernel(source[i], source[j]) + (i == j ? Double(lambda) : 0)
            }
            L[i * m + n] = 1
            L[i * m + n + 1] = Double(source[i].x)
            L[i * m + n + 2] = Double(source[i].y)
            L[n * m + i] = 1
            L[(n + 1) * m + i] = Double(source[i].x)
            L[(n + 2) * m + i] = Double(source[i].y)
        }
        var B = [Double](repeating: 0, count: m * 2)
        for i in 0..<n { B[i * 2] = Double(target[i].x); B[i * 2 + 1] = Double(target[i].y) }
        guard let sol = DenseSolver.solve(L, B, n: m, k: 2) else { return nil }
        sources = source
        weights = (0..<n).map { SIMD2(Float(sol.x[$0 * 2]), Float(sol.x[$0 * 2 + 1])) }
        affine = (0..<3).map { SIMD2(Float(sol.x[(n + $0) * 2]), Float(sol.x[(n + $0) * 2 + 1])) }
        pivotRatio = sol.pivotRatio
    }

    public func map(_ p: SIMD2<Float>) -> SIMD2<Float> {
        var out = affine[0] + affine[1] * p.x + affine[2] * p.y
        for (s, w) in zip(sources, weights) {
            let r2 = simd_length_squared(p - s)
            if r2 > 1e-12 { out += w * (r2 * log(r2)) }
        }
        return out
    }
}
