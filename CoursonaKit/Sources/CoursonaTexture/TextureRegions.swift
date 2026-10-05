//
//  TextureRegions.swift
//  CoursonaTexture
//
//  19차 — 얼굴 패치 **밖** 부위의 관측 정리. 실기기 2k 알베도(iPhone 5컷)에서 얼굴은 깨끗한데 목·귀·눈꺼풀 안쪽이 조각나 보였던 원인:
//   · 목·귀는 템플릿 기하가 사용자의 목·셔츠 깃·귀와 1–3 cm 어긋나 깊이·각도 검사를 통과한 관측이 **드문드문** 들어오고, 그 색도
//     셔츠 흰색·머리카락·정반사·턱 밑 그늘이 섞여 있다 → 관측(빨강)과 채움(파랑)이 텍셀 단위로 뒤섞여 렌더에서 "깨진 유리" 처럼 보인다.
//   · 눈꺼풀 안쪽(LidInner)·입술 안쪽(LipInner) 띠는 카메라가 그 자리에서 **눈알·치아** 를 보므로 관측을 받으면 안 된다.
//  처리(모두 CPU, 누적 뒤 · 채움 전):
//   ① 피부 기준색 = 얼굴 패치 관측 텍셀의 채널별 중앙값.
//   ② 피부 게이트: 기준색 대비 색도(r, g 비율) 거리·밝기 비로 비피부 관측을 버린다(셔츠 (180,190,210) Δr 0.11 · 하이라이트 Δr 0.09 · 머리카락 밝기 0.25).
//   ③ 저주파화: 남은 관측을 셀 격자(2k 에서 8 텍셀)로 내려 가우시안(σ = 24 텍셀@2k, 해상도 비례) 으로 흐린 뒤 다시 올린다 — 이 부위는
//      사진 해상도로 복원할 세부가 없고(어긋난 기하에 투영된 세부는 거짓 세부다) 색조만 맞으면 된다. 커버리지가 낮은 곳은 비워 pull-push 가 메운다.
//   ④ 두피는 머리카락 기준 밝기(관측 두피 중앙값) 의 2배 넘는 하이라이트(창문 반사)만 버리고 같은 저주파화.
//   ⑤ LidInner ← 피부 기준색을 조금 어둡고 붉게, LipInner ← 입술색 × 0.45 (관측 무시).
//

import Foundation
import simd
import CoursonaCore

public enum TextureRegions {
    public struct SkinGate: Sendable, Equatable {
        /// 색도 거리 |Δr| + |Δg| 상한 (r = R/(R+G+B), g = G/(R+G+B))
        public var chromaTolerance: Float = 0.055
        /// 밝기 비(기준 대비) 허용 범위
        public var lumaRange: ClosedRange<Float> = 0.4...1.6
        public init() {}
        public static let skin = SkinGate()
        /// 머리카락: **밝기만** 본다(기준의 2배 넘는 창문 반사·흰 하이라이트 제거). 어두운 색은 색도 비율이 수치적으로 불안정하고, 두피 기준색(채널별 중앙값)은
        /// 밝기 분포가 양봉이면 실제 텍셀과 동떨어진 회색이 돼 색도 게이트가 멀쩡한 머리카락을 거의 다 버렸다(합성 두피 2554 → 153).
        public static var hair: SkinGate { var g = SkinGate(); g.chromaTolerance = .infinity; g.lumaRange = 0...2.0; return g }
    }

    /// 관측 또는 대칭 복사 텍셀 — 게이트·저주파화의 입력. 대칭 복사 **뒤**에 돌리므로 복사본도 같은 검사를 받는다.
    @inline(__always) static func isSource(_ s: UInt8) -> Bool {
        s == TextureFill.TexelState.observed.rawValue || s == TextureFill.TexelState.mirrored.rawValue
    }
    @inline(__always) static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
    @inline(__always) static func chroma(_ c: SIMD3<Float>) -> SIMD2<Float> {
        let s = max(1e-4, c.x + c.y + c.z)
        return SIMD2(c.x / s, c.y / s)
    }

    /// 마스크 안 관측(또는 대칭 복사) 텍셀의 채널별 중앙값 (stride 로 부표본). 50개 미만이면 nil.
    public static func medianColor(albedo: [SIMD3<Float>], state: [UInt8], mask: [Bool], stride: Int = 4) -> SIMD3<Float>? {
        var r: [Float] = [], g: [Float] = [], b: [Float] = []
        var i = 0
        while i < albedo.count {
            if mask[i] && isSource(state[i]) { r.append(albedo[i].x); g.append(albedo[i].y); b.append(albedo[i].z) }
            i += max(1, stride)
        }
        guard r.count >= 50 else { return nil }
        r.sort(); g.sort(); b.sort()
        return SIMD3(r[r.count / 2], g[g.count / 2], b[b.count / 2])
    }

    public static func isSkinLike(_ c: SIMD3<Float>, reference ref: SIMD3<Float>, gate: SkinGate) -> Bool {
        if gate.chromaTolerance.isFinite {
            let d = chroma(c) - chroma(ref)
            guard abs(d.x) + abs(d.y) <= gate.chromaTolerance else { return false }
        }
        let ratio = luma(c) / max(1e-4, luma(ref))
        return gate.lumaRange.contains(ratio)
    }

    /// 마스크 안 관측 텍셀 중 게이트에 걸리는 것을 비운다. 반환: 비운 수.
    public static func rejectNonSkin(albedo: inout [SIMD3<Float>], state: inout [UInt8], mask: [Bool], reference: SIMD3<Float>, gate: SkinGate) -> Int {
        var n = 0
        for i in albedo.indices where mask[i] && isSource(state[i]) && !isSkinLike(albedo[i], reference: reference, gate: gate) {
            albedo[i] = .zero; state[i] = TextureFill.TexelState.empty.rawValue; n += 1
        }
        return n
    }

    /// 저주파화. `mask` 안의 관측 텍셀을 `cell` 텍셀 격자로 내려 가우시안(σ `sigmaCells` 셀) 으로 흐린 뒤 `mask` 안 모든 텍셀에 쌍선형으로 올린다.
    /// 커버리지(흐린 관측 수 / 흐린 마스크 텍셀 수, 0…1) 가 `minCoverage` 이상이면 색을 쓰고(`blendTo` 가 있으면 그쪽으로 `blend` 만큼 섞는다), 관측·대칭이던 텍셀은 상태를
    /// 유지하고 아니던 텍셀은 filled 로 표시한다. 커버리지가 모자라면 비운다(홀로 떨어진 관측 포함 — pull-push 가 메운다).
    /// 반환: (새로 채운 수, 비운 관측 수).
    @discardableResult
    public static func lowPass(albedo: inout [SIMD3<Float>], state: inout [UInt8], mask: [Bool], size S: Int, cell: Int, sigmaCells: Float,
                               minCoverage: Float, blendTo: SIMD3<Float>? = nil, blend: Float = 0) -> (filled: Int, cleared: Int) {
        let cellN = max(1, cell)
        let L = (S + cellN - 1) / cellN
        var sum = [SIMD3<Float>](repeating: .zero, count: L * L)
        var cnt = [Float](repeating: 0, count: L * L)
        var area = [Float](repeating: 0, count: L * L)   // 셀 안 마스크 텍셀 수 (커버리지 분모 — 섬 가장자리·가는 띠에서 관측이 억울하게 비워지지 않게)
        var any = false
        for y in 0..<S { for x in 0..<S {
            let i = y * S + x
            guard mask[i] else { continue }
            let c = (y / cellN) * L + x / cellN
            area[c] += 1
            guard isSource(state[i]) else { continue }
            sum[c] += albedo[i]; cnt[c] += 1; any = true
        } }
        guard any else { return (0, 0) }
        // 분리 가우시안 (반지름 3σ)
        let r = max(1, Int((3 * sigmaCells).rounded(.up)))
        let k = (0...r).map { exp(-Float($0 * $0) / (2 * sigmaCells * sigmaCells)) }
        func blur(_ src: [SIMD3<Float>], _ w: [Float]) -> ([SIMD3<Float>], [Float]) {
            var s1 = src, w1 = w
            for y in 0..<L { for x in 0..<L {
                var a = SIMD3<Float>.zero, b: Float = 0
                for d in -r...r { let xx = x + d; guard xx >= 0, xx < L else { continue }; let g = k[abs(d)]; a += src[y * L + xx] * g; b += w[y * L + xx] * g }
                s1[y * L + x] = a; w1[y * L + x] = b
            } }
            var s2 = s1, w2 = w1
            for y in 0..<L { for x in 0..<L {
                var a = SIMD3<Float>.zero, b: Float = 0
                for d in -r...r { let yy = y + d; guard yy >= 0, yy < L else { continue }; let g = k[abs(d)]; a += s1[yy * L + x] * g; b += w1[yy * L + x] * g }
                s2[y * L + x] = a; w2[y * L + x] = b
            } }
            return (s2, w2)
        }
        let (bs, bw) = blur(sum, cnt)
        let (_, ba) = blur(sum, area)
        var filled = 0, cleared = 0
        for y in 0..<S { for x in 0..<S {
            let i = y * S + x
            guard mask[i] else { continue }
            let fx = min(Float(L) - 1, max(0, (Float(x) + 0.5) / Float(cellN) - 0.5)), fy = min(Float(L) - 1, max(0, (Float(y) + 0.5) / Float(cellN) - 0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(L - 1, x0 + 1), y1 = min(L - 1, y0 + 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
            let wsum = bw[y0 * L + x0] * w00 + bw[y0 * L + x1] * w10 + bw[y1 * L + x0] * w01 + bw[y1 * L + x1] * w11
            let asum = ba[y0 * L + x0] * w00 + ba[y0 * L + x1] * w10 + ba[y1 * L + x0] * w01 + ba[y1 * L + x1] * w11
            let coverage = asum > 0 ? wsum / asum : 0
            let wasObserved = isSource(state[i])
            if coverage >= minCoverage, wsum > 0 {
                let csum = bs[y0 * L + x0] * w00 + bs[y0 * L + x1] * w10 + bs[y1 * L + x0] * w01 + bs[y1 * L + x1] * w11
                var c = csum / wsum
                if let t = blendTo, blend > 0 { c = c * (1 - blend) + t * blend }
                albedo[i] = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
                if !wasObserved { state[i] = TextureFill.TexelState.filled.rawValue; filled += 1 }
            } else if wasObserved {
                albedo[i] = .zero; state[i] = TextureFill.TexelState.empty.rawValue; cleared += 1
            }
        } }
        return (filled, cleared)
    }

    /// 마스크 안 텍셀을 전부 한 색으로 (관측도 덮어쓴다 — 눈꺼풀·입술 안쪽처럼 관측이 틀린 띠). 반환: 쓴 수.
    @discardableResult
    public static func paint(albedo: inout [SIMD3<Float>], state: inout [UInt8], mask: [Bool], color: SIMD3<Float>) -> Int {
        var n = 0
        for i in albedo.indices where mask[i] { albedo[i] = color; state[i] = TextureFill.TexelState.filled.rawValue; n += 1 }
        return n
    }

    /// 입술색: 얼굴 패치 관측 중 `mouthUV` 반경 `radius` 안 텍셀의 중앙값 (없으면 nil).
    public static func lipColor(albedo: [SIMD3<Float>], state: [UInt8], faceMask: [Bool], size S: Int, mouthUV: SIMD2<Float>, radius: Float) -> SIMD3<Float>? {
        var mask = [Bool](repeating: false, count: S * S)
        let r2 = radius * radius
        for y in 0..<S { for x in 0..<S {
            let i = y * S + x
            guard faceMask[i] else { continue }
            let u = (Float(x) + 0.5) / Float(S), v = 1 - (Float(y) + 0.5) / Float(S)
            if simd_length_squared(SIMD2(u, v) - mouthUV) < r2 { mask[i] = true }
        } }
        return medianColor(albedo: albedo, state: state, mask: mask, stride: 1)
    }
}
