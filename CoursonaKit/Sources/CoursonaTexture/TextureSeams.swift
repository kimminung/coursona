//
//  TextureSeams.swift
//  CoursonaTexture
//
//  T-403 접합 저주파 색 보정. 컷마다 노출·화이트밸런스가 달라 겹치는 영역에 색 단차가 생긴다.
//  UV 를 G×G(기본 32×32) 격자로 나누고 컷별 셀 평균색 μ_s(c)·가중치 W_s(c) 를 저해상도 투영에서 모은 뒤, 컷별 셀 **게인** g_s(c)(RGB) 를
//      E = Σ_c Σ_{s<t} ω_st(c) ‖g_s μ_s − g_t μ_t‖²  +  λ_s Σ_s Σ_{c~c'} ‖g_s(c) − g_s(c')‖²  +  Σ_s λ_p(s) Σ_c (W_s(c)+ε) ‖g_s(c) − 1‖²
//  로 푼다(ω_st = min(W_s, W_t), 정규화된 가중치). 정면 컷은 사전항을 강하게(λ_p 0.5) 두어 **정면 노출에 앵커**하고 나머지(0.02)가 거기 맞춰진다.
//  SPD 선형계 → `ConjugateGradient`(채널 3개를 SIMD3 로 한 번에). 결과 게인은 전체 해상도 누적에서 셀 중심 쌍선형 보간으로 곱한다.
//  `seamDelta`(품질 카드) = 겹침 셀에서 ω 가중 평균 |g_sμ_s − g_tμ_t| (0…255) — 보정 전/후 둘 다 기록한다.
//

import Foundation
import simd
import CoursonaCore

public struct SeamGains: Sendable {
    public var grid: Int
    public var shots: Int
    /// [shot][cell] (cell = y·grid + x), RGB 게인
    public var gains: [[SIMD3<Float>]]
    public var seamDeltaBefore: Float
    public var seamDeltaAfter: Float
    public var cgIterations: Int

    public static func identity(grid: Int, shots: Int) -> SeamGains {
        SeamGains(grid: grid, shots: shots, gains: Array(repeating: Array(repeating: SIMD3(repeating: 1), count: grid * grid), count: shots),
                  seamDeltaBefore: 0, seamDeltaAfter: 0, cgIterations: 0)
    }

    /// 텍셀 UV 의 게인 (셀 중심 쌍선형).
    @inline(__always) public func gain(shot s: Int, u: Float, v: Float) -> SIMD3<Float> {
        let G = grid
        let fx = min(Float(G) - 1, max(0, u * Float(G) - 0.5)), fy = min(Float(G) - 1, max(0, (1 - v) * Float(G) - 0.5))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(G - 1, x0 + 1), y1 = min(G - 1, y0 + 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let g = gains[s]
        let top = g[y0 * G + x0] * (1 - tx) + g[y0 * G + x1] * tx
        let bot = g[y1 * G + x0] * (1 - tx) + g[y1 * G + x1] * tx
        return top * (1 - ty) + bot * ty
    }
}

public enum TextureSeams {
    /// 저해상도 투영(컷별 Σw·색, Σw, 크기 L×L) 에서 셀 통계를 만들어 게인을 푼다.
    /// - Parameters: colorSum[s][i] = Σ w·색, weight[s][i] = Σ w (L×L, 텍셀 행 y 는 1−v 방향).
    public static func solve(colorSum: [[SIMD3<Float>]], weight: [[Float]], lowRes L: Int, grid G: Int,
                             anchorShot: Int, smoothness: Float = 1, priorOther: Float = 0.02, priorAnchor: Float = 0.5) -> SeamGains {
        let S = colorSum.count
        let C = G * G
        guard S > 0 else { return .identity(grid: G, shots: 0) }
        // 셀 통계
        var mu = [[SIMD3<Float>]](repeating: [SIMD3<Float>](repeating: .zero, count: C), count: S)
        var W = [[Float]](repeating: [Float](repeating: 0, count: C), count: S)
        for s in 0..<S {
            var acc = [SIMD3<Float>](repeating: .zero, count: C), ws = [Float](repeating: 0, count: C)
            for y in 0..<L {
                let cy = min(G - 1, y * G / L)
                for x in 0..<L {
                    let w = weight[s][y * L + x]
                    guard w > 0 else { continue }
                    let c = cy * G + min(G - 1, x * G / L)
                    acc[c] += colorSum[s][y * L + x]; ws[c] += w
                }
            }
            for c in 0..<C where ws[c] > 0 { mu[s][c] = acc[c] / ws[c]; W[s][c] = ws[c] }
        }
        // 가중치 정규화 (평균 1)
        var wsum: Float = 0, wn: Float = 0
        for s in 0..<S { for c in 0..<C where W[s][c] > 0 { wsum += W[s][c]; wn += 1 } }
        let wmean = wn > 0 ? wsum / wn : 1
        for s in 0..<S { for c in 0..<C { W[s][c] /= wmean } }
        // 겹침 쌍
        struct Pair { var s: Int; var t: Int; var c: Int; var w: Float }
        var pairs: [Pair] = []
        for c in 0..<C { for s in 0..<S { for t in (s + 1)..<S where W[s][c] > 0 && W[t][c] > 0 { pairs.append(Pair(s: s, t: t, c: c, w: min(W[s][c], W[t][c]))) } } }
        func seamDelta(_ g: [SIMD3<Float>]) -> Float {
            var num: Float = 0, den: Float = 0
            for p in pairs {
                let d = g[p.s * C + p.c] * mu[p.s][p.c] - g[p.t * C + p.c] * mu[p.t][p.c]
                num += p.w * (abs(d.x) + abs(d.y) + abs(d.z)) / 3; den += p.w
            }
            return den > 0 ? num / den * 255 : 0
        }
        let ones = [SIMD3<Float>](repeating: SIMD3(repeating: 1), count: S * C)
        let before = seamDelta(ones)
        guard !pairs.isEmpty else { return SeamGains(grid: G, shots: S, gains: Array(repeating: ones[0..<C].map { $0 }, count: S), seamDeltaBefore: before, seamDeltaAfter: before, cgIterations: 0) }

        let eps: Float = 0.01
        func prior(_ s: Int) -> Float { s == anchorShot ? priorAnchor : priorOther }
        // 이웃 (4-연결)
        func neighbors(_ c: Int) -> [Int] {
            let x = c % G, y = c / G
            var out: [Int] = []
            if x > 0 { out.append(c - 1) }; if x + 1 < G { out.append(c + 1) }
            if y > 0 { out.append(c - G) }; if y + 1 < G { out.append(c + G) }
            return out
        }
        let nbr = (0..<C).map(neighbors)
        // b = 사전항 (g → 1)
        var b = [SIMD3<Float>](repeating: .zero, count: S * C)
        var diag = [SIMD3<Float>](repeating: .zero, count: S * C)
        for s in 0..<S { for c in 0..<C {
            let pw = prior(s) * (W[s][c] + eps)
            b[s * C + c] = SIMD3(repeating: pw)
            diag[s * C + c] = SIMD3(repeating: pw + smoothness * Float(nbr[c].count))
        } }
        for p in pairs {
            diag[p.s * C + p.c] += mu[p.s][p.c] * mu[p.s][p.c] * p.w
            diag[p.t * C + p.c] += mu[p.t][p.c] * mu[p.t][p.c] * p.w
        }
        let sol = ConjugateGradient.solve(b: b, x0: ones, diagonal: diag, maxIterations: 300, tolerance: 1e-6) { x in
            var out = [SIMD3<Float>](repeating: .zero, count: S * C)
            for s in 0..<S { for c in 0..<C {
                let i = s * C + c
                var v = x[i] * (prior(s) * (W[s][c] + eps))
                for j in nbr[c] { v += (x[i] - x[s * C + j]) * smoothness }
                out[i] = v
            } }
            for p in pairs {
                let i = p.s * C + p.c, j = p.t * C + p.c
                let r = (x[i] * mu[p.s][p.c] - x[j] * mu[p.t][p.c]) * p.w
                out[i] += r * mu[p.s][p.c]
                out[j] -= r * mu[p.t][p.c]
            }
            return out
        }
        var g = sol.x
        for i in g.indices { g[i] = simd_clamp(g[i], SIMD3(repeating: 0.5), SIMD3(repeating: 2)) }
        var gains: [[SIMD3<Float>]] = []
        for s in 0..<S { gains.append(Array(g[(s * C)..<((s + 1) * C)])) }
        return SeamGains(grid: G, shots: S, gains: gains, seamDeltaBefore: before, seamDeltaAfter: seamDelta(g), cgIterations: sol.iterations)
    }
}
