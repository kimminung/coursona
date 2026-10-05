//
//  TextureFill.swift
//  CoursonaTexture
//
//  T-405 채움 · T-406 피부 필터 (CPU).
//  ① 대칭 복사: 미관측 텍셀의 삼각형 → 거울 삼각형(원본 정점 대칭 맵으로 미리 계산) 의 코너 UV + 같은 무게중심 → 그 UV 가 관측됐으면 복사.
//     렌더 메시는 솔기에서 정점이 갈라져 정점 대칭 맵을 그대로 못 쓰므로 **삼각형 단위**로 맞춘다.
//  ② 두피: 머리카락이 덮인 두피는 깊이·색 모두 머리카락이라 "관측된 두피 텍셀의 평균색" 으로 채운다(사용자 머리카락색).
//  ③ pull-push: (색·가중치) 피라미드를 1×1 까지 내렸다가 올라오며 빈 곳을 채운다. 전체 해상도 바로 아래 레벨부터 만들어 메모리를 1/4 로.
//  ④ 양방향 필터(피부 가이드, σ_s 3 텍셀 · σ_c 0.08): 얼굴 UV 영역의 관측·대칭 텍셀만, 가로·세로 분리 근사.
//  mask: R = 관측 · G = 대칭 복사 · B = 채움(두피 포함).
//

import Foundation
import simd
import CoursonaCore

public enum TextureFill {
    public enum TexelState: UInt8 { case empty = 0, observed = 1, mirrored = 2, filled = 3 }

    /// 삼각형별 **거울 코너 UV** (코너 k 의 원본 정점 → 대칭 정점 → 그 정점의 코너 UV 중 세 코너가 같은 UV 섬에 있는 조합).
    /// 거울 사각형은 반대 대각선으로 삼각분할돼 있어 "같은 정점 집합의 삼각형" 은 대개 없다(합성 80/13360) — 그래서 정점 단위로 간다.
    /// 솔기 정점은 코너 UV 가 둘 이상이라 세 UV 의 최대 거리가 가장 작은 조합을 고른다. 없으면 valid = false.
    public struct MirrorUV: Sendable {
        public var uv: [SIMD2<Float>]      // 3 × T
        public var valid: [Bool]           // T
    }

    public static func mirrorTriangles(render: BustTemplate.RenderMesh, symmetryMap: [Int32]) -> MirrorUV {
        let T = render.indices.count / 3
        var out = MirrorUV(uv: [SIMD2<Float>](repeating: .zero, count: T * 3), valid: [Bool](repeating: false, count: T))
        guard symmetryMap.count > 0 else { return out }
        // 원본 정점 → 렌더 정점들의 UV
        var uvOf: [Int: [SIMD2<Float>]] = [:]
        for (r, s) in render.sourceIndex.enumerated() { uvOf[Int(s), default: []].append(render.uvs[r]) }
        for t in 0..<T {
            var cands: [[SIMD2<Float>]] = []
            var ok = true
            for k in 0..<3 {
                let s = Int(render.sourceIndex[Int(render.indices[t * 3 + k])])
                guard s < symmetryMap.count, symmetryMap[s] >= 0, let list = uvOf[Int(symmetryMap[s])], !list.isEmpty else { ok = false; break }
                cands.append(Array(list.prefix(4)))
            }
            guard ok else { continue }
            var best: (Float, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)? = nil
            for a in cands[0] { for b in cands[1] { for c in cands[2] {
                let d = max(simd_length(a - b), simd_length(b - c), simd_length(a - c))
                if best == nil || d < best!.0 { best = (d, a, b, c) }
            } } }
            guard let (d, a, b, c) = best, d < 0.25 else { continue }
            out.uv[t * 3] = a; out.uv[t * 3 + 1] = b; out.uv[t * 3 + 2] = c
            out.valid[t] = true
        }
        return out
    }

    /// 대칭 복사. `triID/bary` 는 텍셀 래스터.
    public static func mirrorCopy(albedo: inout [SIMD3<Float>], state: inout [UInt8], size S: Int,
                                  triID: [Int32], bary: [SIMD2<UInt16>], render: BustTemplate.RenderMesh, mirror: MirrorUV) -> Int {
        var count = 0
        let src = albedo, srcState = state
        for y in 0..<S {
            for x in 0..<S {
                let i = y * S + x
                guard srcState[i] == TexelState.empty.rawValue, triID[i] >= 0 else { continue }
                let t = Int(triID[i])
                guard mirror.valid[t] else { continue }
                let b = TexelRaster.barycentric(bary[i])
                let uv = mirror.uv[t * 3] * b.x + mirror.uv[t * 3 + 1] * b.y + mirror.uv[t * 3 + 2] * b.z
                let mx = min(S - 1, max(0, Int(uv.x * Float(S)))), my = min(S - 1, max(0, Int((1 - uv.y) * Float(S))))
                let j = my * S + mx
                guard srcState[j] == TexelState.observed.rawValue else { continue }
                albedo[i] = src[j]
                state[i] = TexelState.mirrored.rawValue
                count += 1
            }
        }
        return count
    }

    /// 두피: 관측된 두피 텍셀 평균색으로 빈 두피 텍셀을 채운다. 반환: (채운 수, 머리카락색).
    public static func fillScalp(albedo: inout [SIMD3<Float>], state: inout [UInt8], isScalp: [Bool]) -> (Int, SIMD3<Float>?) {
        fillUniform(albedo: &albedo, state: &state, sourceMask: isScalp, targetMask: isScalp)
    }

    /// `sourceMask` 에서 관측된(observed) 텍셀의 평균색으로 `targetMask` 의 빈 텍셀을 채운다. 반환: (채운 수, 평균색).
    /// 어깨(Shoulders) 처럼 **직접 관측이 항상 다른 물체(옷) 색** 이라 그 평균을 못 믿는 영역에, 믿을 수 있는 다른 영역(목)의 평균을 대신 쓴다.
    public static func fillUniform(albedo: inout [SIMD3<Float>], state: inout [UInt8], sourceMask: [Bool], targetMask: [Bool]) -> (Int, SIMD3<Float>?) {
        var sum = SIMD3<Float>.zero, n: Float = 0
        for i in albedo.indices where sourceMask[i] && state[i] == TexelState.observed.rawValue { sum += albedo[i]; n += 1 }
        guard n >= 50 else { return (0, nil) }
        let avg = sum / n
        var count = 0
        for i in albedo.indices where targetMask[i] && state[i] == TexelState.empty.rawValue { albedo[i] = avg; state[i] = TexelState.filled.rawValue; count += 1 }
        return (count, avg)
    }

    /// pull-push 확산. 메시 안(`inside`)의 빈 텍셀을 채우고 `filled` 로 표시한다. 메시 밖도 채운다(밉맵 번짐 방지)만 세지 않는다.
    public static func pullPush(albedo: inout [SIMD3<Float>], state: inout [UInt8], inside: [Bool], size S: Int) -> Int {
        // 레벨 1 (S/2) 부터 피라미드
        var levels: [(c: [SIMD3<Float>], w: [Float], n: Int)] = []
        var n = S / 2
        var c = [SIMD3<Float>](repeating: .zero, count: n * n), w = [Float](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n {
            var cs = SIMD3<Float>.zero, ws: Float = 0
            for dy in 0..<2 { for dx in 0..<2 {
                let i = (y * 2 + dy) * S + (x * 2 + dx)
                if state[i] != TexelState.empty.rawValue { cs += albedo[i]; ws += 1 }
            } }
            if ws > 0 { c[y * n + x] = cs / ws; w[y * n + x] = min(1, ws / 4) }
        } }
        levels.append((c, w, n))
        while n > 1 {
            let m = n / 2
            var c2 = [SIMD3<Float>](repeating: .zero, count: m * m), w2 = [Float](repeating: 0, count: m * m)
            let (pc, pw, _) = levels[levels.count - 1]
            for y in 0..<m { for x in 0..<m {
                var cs = SIMD3<Float>.zero, ws: Float = 0
                for dy in 0..<2 { for dx in 0..<2 {
                    let i = (y * 2 + dy) * n + (x * 2 + dx)
                    cs += pc[i] * pw[i]; ws += pw[i]
                } }
                if ws > 0 { c2[y * m + x] = cs / ws; w2[y * m + x] = min(1, ws / 4) }
            } }
            levels.append((c2, w2, m))
            n = m
        }
        // push: 거친 → 고운
        var li = levels.count - 1
        while li > 0 {
            let (cc, cw, cn) = levels[li]
            var (fc, fw, fn) = levels[li - 1]
            for y in 0..<fn { for x in 0..<fn {
                let i = y * fn + x
                if fw[i] >= 1 { continue }
                // 쌍선형 업샘플
                let gx = (Float(x) + 0.5) / 2 - 0.5, gy = (Float(y) + 0.5) / 2 - 0.5
                let x0 = max(0, min(cn - 1, Int(gx.rounded(.down)))), y0 = max(0, min(cn - 1, Int(gy.rounded(.down))))
                let x1 = min(cn - 1, x0 + 1), y1 = min(cn - 1, y0 + 1)
                let tx = max(0, min(1, gx - Float(x0))), ty = max(0, min(1, gy - Float(y0)))
                let up = cc[y0 * cn + x0] * (1 - tx) * (1 - ty) + cc[y0 * cn + x1] * tx * (1 - ty) + cc[y1 * cn + x0] * (1 - tx) * ty + cc[y1 * cn + x1] * tx * ty
                let upw = cw[y0 * cn + x0] * (1 - tx) * (1 - ty) + cw[y0 * cn + x1] * tx * (1 - ty) + cw[y1 * cn + x0] * (1 - tx) * ty + cw[y1 * cn + x1] * tx * ty
                let total = fw[i] + (1 - fw[i]) * upw
                if total > 0 { fc[i] = (fc[i] * fw[i] + up * (1 - fw[i]) * upw) / total; fw[i] = min(1, total) } else { fc[i] = up }
                if fw[i] <= 0 && upw > 0 { fw[i] = 1e-3 }
            } }
            levels[li - 1] = (fc, fw, fn)
            li -= 1
        }
        // 전체 해상도 빈 텍셀 ← 레벨 1 쌍선형
        let (lc, _, ln) = levels[0]
        var count = 0
        for y in 0..<S { for x in 0..<S {
            let i = y * S + x
            guard state[i] == TexelState.empty.rawValue else { continue }
            let gx = (Float(x) + 0.5) / 2 - 0.5, gy = (Float(y) + 0.5) / 2 - 0.5
            let x0 = max(0, min(ln - 1, Int(gx.rounded(.down)))), y0 = max(0, min(ln - 1, Int(gy.rounded(.down))))
            let x1 = min(ln - 1, x0 + 1), y1 = min(ln - 1, y0 + 1)
            let tx = max(0, min(1, gx - Float(x0))), ty = max(0, min(1, gy - Float(y0)))
            albedo[i] = lc[y0 * ln + x0] * (1 - tx) * (1 - ty) + lc[y0 * ln + x1] * tx * (1 - ty) + lc[y1 * ln + x0] * (1 - tx) * ty + lc[y1 * ln + x1] * tx * ty
            if inside[i] { state[i] = TexelState.filled.rawValue; count += 1 }
        } }
        return count
    }

    /// 피부 양방향 필터 (가로·세로 분리 근사). `apply[i]` 가 true 인 텍셀만 갱신하고, 이웃도 apply 인 것만 섞는다.
    public static func bilateral(albedo: inout [SIMD3<Float>], apply: [Bool], size S: Int, sigmaSpace: Float, sigmaColor: Float) {
        let r = max(1, Int((2 * sigmaSpace).rounded()))
        let sw = (0...r).map { exp(-Float($0 * $0) / (2 * sigmaSpace * sigmaSpace)) }
        let inv2c = 1 / (2 * sigmaColor * sigmaColor)
        func pass(_ src: [SIMD3<Float>], horizontal: Bool) -> [SIMD3<Float>] {
            var out = src
            for y in 0..<S { for x in 0..<S {
                let i = y * S + x
                guard apply[i] else { continue }
                let c0 = src[i]
                var acc = c0, ws: Float = 1
                for d in 1...r {
                    for sgn in [-1, 1] {
                        let xx = horizontal ? x + d * sgn : x, yy = horizontal ? y : y + d * sgn
                        guard xx >= 0, yy >= 0, xx < S, yy < S else { continue }
                        let j = yy * S + xx
                        guard apply[j] else { continue }
                        let c = src[j]
                        let w = sw[d] * exp(-simd_length_squared(c - c0) * inv2c)
                        acc += c * w; ws += w
                    }
                }
                out[i] = acc / ws
            } }
            return out
        }
        albedo = pass(pass(albedo, horizontal: true), horizontal: false)
    }
}
