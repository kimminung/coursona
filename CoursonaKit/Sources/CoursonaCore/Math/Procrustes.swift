//
//  Procrustes.swift
//  CoursonaCore
//
//  스케일 포함 유사 변환(Procrustes). 회전은 Horn(1987) 쿼터니언 법: 4×4 대칭 행렬 N 의 최대 고유벡터를 Jacobi 반복으로 구한다.
//  Accelerate 없이 순수 Swift(결정적). 캡처 5컷 얼굴 메시(1220 정점)를 템플릿 패치에 정합할 때 쓴다(TechPRD §6.4-1).
//

import Foundation
import simd

public struct SimilarityTransform: Sendable, Equatable {
    public var scale: Float
    public var rotation: simd_quatf
    public var translation: SIMD3<Float>

    public init(scale: Float = 1, rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]), translation: SIMD3<Float> = .zero) {
        self.scale = scale; self.rotation = rotation; self.translation = translation
    }
    public static let identity = SimilarityTransform()

    public func apply(_ p: SIMD3<Float>) -> SIMD3<Float> { rotation.act(p) * scale + translation }
    public func apply(_ ps: [SIMD3<Float>]) -> [SIMD3<Float>] { ps.map(apply) }
    /// 스케일을 뺀 강체 부분만 (사용자 치수를 보존하고 자세만 맞출 때).
    public var rigid: SimilarityTransform { SimilarityTransform(scale: 1, rotation: rotation, translation: translation) }
    public var matrix: simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.0 *= scale; m.columns.1 *= scale; m.columns.2 *= scale
        m.columns.3 = SIMD4(translation, 1)
        return m
    }
}

public enum Procrustes {
    /// source → target 유사 변환 (가중 최소제곱). 점이 3개 미만이거나 퇴화하면 nil.
    /// - Parameter allowScale: false 면 scale = 1.
    public static func fit(source: [SIMD3<Float>], target: [SIMD3<Float>], weights: [Float]? = nil, allowScale: Bool = true) -> SimilarityTransform? {
        let n = source.count
        guard n >= 3, target.count == n else { return nil }
        let w: [Float] = weights ?? [Float](repeating: 1, count: n)
        let wsum = w.reduce(0, +)
        guard wsum > 0 else { return nil }
        var cs = SIMD3<Float>.zero, ct = SIMD3<Float>.zero
        for i in 0..<n { cs += source[i] * w[i]; ct += target[i] * w[i] }
        cs /= wsum; ct /= wsum

        // 공분산 (double 누적)
        var S = [Double](repeating: 0, count: 9)   // S[r*3+c] = Σ w · s_r · t_c
        var varS = 0.0
        for i in 0..<n {
            let a = SIMD3<Double>(source[i] - cs), b = SIMD3<Double>(target[i] - ct), wi = Double(w[i])
            S[0] += wi * a.x * b.x; S[1] += wi * a.x * b.y; S[2] += wi * a.x * b.z
            S[3] += wi * a.y * b.x; S[4] += wi * a.y * b.y; S[5] += wi * a.y * b.z
            S[6] += wi * a.z * b.x; S[7] += wi * a.z * b.y; S[8] += wi * a.z * b.z
            varS += wi * simd_length_squared(a)
        }
        guard varS > 1e-18 else { return nil }
        let Sxx = S[0], Sxy = S[1], Sxz = S[2], Syx = S[3], Syy = S[4], Syz = S[5], Szx = S[6], Szy = S[7], Szz = S[8]
        // Horn 의 N 행렬
        var N = [Double](repeating: 0, count: 16)
        N[0] = Sxx + Syy + Szz; N[1] = Syz - Szy;        N[2] = Szx - Sxz;        N[3] = Sxy - Syx
        N[4] = N[1];            N[5] = Sxx - Syy - Szz;  N[6] = Sxy + Syx;        N[7] = Szx + Sxz
        N[8] = N[2];            N[9] = N[6];             N[10] = -Sxx + Syy - Szz; N[11] = Syz + Szy
        N[12] = N[3];           N[13] = N[7];            N[14] = N[11];           N[15] = -Sxx - Syy + Szz
        guard let (eigval, q) = JacobiEigen.maxEigenpair4(N) else { return nil }
        let rot = simd_normalize(simd_quatf(ix: Float(q[1]), iy: Float(q[2]), iz: Float(q[3]), r: Float(q[0])))
        // 스케일: Horn — s = (Σ w·(R a)·b) / Σ w|a|² = λmax / varS
        let scale: Float = allowScale ? Float(max(1e-6, eigval / varS)) : 1
        let t = ct - rot.act(cs) * scale
        return SimilarityTransform(scale: scale, rotation: rot, translation: t)
    }

    /// 정합 후 RMS (m).
    public static func rms(source: [SIMD3<Float>], target: [SIMD3<Float>], transform: SimilarityTransform) -> Float {
        guard !source.isEmpty, source.count == target.count else { return .nan }
        var s: Float = 0
        for i in source.indices { s += simd_length_squared(transform.apply(source[i]) - target[i]) }
        return (s / Float(source.count)).squareRoot()
    }
}

/// 4×4 대칭 행렬 Jacobi 고유분해 (순수 Swift).
public enum JacobiEigen {
    /// 최대 고유값과 그 고유벡터.
    public static func maxEigenpair4(_ A: [Double]) -> (Double, [Double])? {
        precondition(A.count == 16)
        var a = A
        var v = [Double](repeating: 0, count: 16)
        for i in 0..<4 { v[i * 4 + i] = 1 }
        for _ in 0..<60 {
            // 최대 비대각 원소
            var p = 0, q = 1, big = 0.0
            for i in 0..<4 { for j in (i + 1)..<4 where abs(a[i * 4 + j]) > big { big = abs(a[i * 4 + j]); p = i; q = j } }
            if big < 1e-15 { break }
            let app = a[p * 4 + p], aqq = a[q * 4 + q], apq = a[p * 4 + q]
            let theta = 0.5 * atan2(2 * apq, aqq - app)
            let c = cos(theta), s = sin(theta)
            for k in 0..<4 {
                let akp = a[k * 4 + p], akq = a[k * 4 + q]
                a[k * 4 + p] = c * akp - s * akq
                a[k * 4 + q] = s * akp + c * akq
            }
            for k in 0..<4 {
                let apk = a[p * 4 + k], aqk = a[q * 4 + k]
                a[p * 4 + k] = c * apk - s * aqk
                a[q * 4 + k] = s * apk + c * aqk
            }
            for k in 0..<4 {
                let vkp = v[k * 4 + p], vkq = v[k * 4 + q]
                v[k * 4 + p] = c * vkp - s * vkq
                v[k * 4 + q] = s * vkp + c * vkq
            }
        }
        var best = 0, bestVal = -Double.greatestFiniteMagnitude
        for i in 0..<4 where a[i * 4 + i] > bestVal { bestVal = a[i * 4 + i]; best = i }
        let vec = (0..<4).map { v[$0 * 4 + best] }
        guard vec.allSatisfy({ $0.isFinite }) else { return nil }
        return (bestVal, vec)
    }
}
