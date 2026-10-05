//
//  CPUTextureProjector.swift
//  CoursonaTexture
//
//  다시점 투영 텍스처의 **CPU 참조 구현** (TechPRD §6.5 의 가시성·투영·탈조명·대칭 채움). M4 에서 Metal 커널로 옮기고 이 구현은
//  작은 해상도(256²) 단위 테스트의 정답으로 남긴다. 접합 저주파 보정·pull-push·피부 필터는 M4.
//

import Foundation
import simd
import CoursonaCore

public struct TextureProjectionOptions: Sendable {
    public var size = 512
    /// 캡처 깊이와 렌더 깊이 허용 차 (m)
    public var depthTolerance: Float = 0.015
    /// 탈조명 강도 0…1 (0 = 원본 그대로)
    public var delight: Float = 1
    /// 미소 컷 입 주변 제외 (UV 영역 기준)
    public var excludeMouthInSmile = true
    /// 대칭 복사 채움
    public var mirrorFill = true
    public init() {}
}

public struct TextureProjectionResult: Sendable {
    public var albedo: RGBAImage
    /// R = 관측(255) / G = 대칭 복사(255) / B = 채움(255)
    public var mask: RGBAImage
    public var quality: TextureQuality
}

public enum CPUTextureProjector {
    public static func project(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32],
                               shots: [CaptureShot], symmetryMap: [Int32] = [], mouthUVCenter: SIMD2<Float>? = nil,
                               options o: TextureProjectionOptions = TextureProjectionOptions()) -> TextureProjectionResult {
        let start = Date()
        let S = o.size
        let (triID, bary) = SoftwareRasterizer.rasterizeUV(uvs: uvs, indices: indices, size: S)
        var accum = [SIMD3<Float>](repeating: .zero, count: S * S)
        var wsum = [Float](repeating: 0, count: S * S)
        // 컷별 전처리: 월드→카메라, 깊이 intrinsics
        struct ShotCtx { var w2c: simd_float4x4; var K: Geometry.Intrinsics; var Kd: Geometry.Intrinsics?; var image: RGBAImage; var depth: DepthMap?; var light: SIMD3<Float>?; var isSmile: Bool; var camPos: SIMD3<Float> }
        var ctxs: [ShotCtx] = []
        for s in shots {
            guard let img = s.image else { continue }
            let light = s.meta.light.primaryDirection.flatMap { $0.count == 3 ? simd_normalize(SIMD3<Float>($0[0], $0[1], $0[2])) : nil }
            let cam = s.cameraTransform
            ctxs.append(ShotCtx(w2c: cam.inverse, K: s.meta.intrinsics.scaled(toWidth: img.width, height: img.height), Kd: s.depthIntrinsics,
                                image: img, depth: s.depth, light: light, isSmile: s.kind == .smile,
                                camPos: SIMD3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)))
        }
        var observed = 0, texels = 0
        for idx in 0..<(S * S) where triID[idx] >= 0 {
            texels += 1
            let t3 = Int(triID[idx]) * 3
            let ia = Int(indices[t3]), ib = Int(indices[t3 + 1]), ic = Int(indices[t3 + 2])
            let b = bary[idx]
            let pos = positions[ia] * b.x + positions[ib] * b.y + positions[ic] * b.z
            let nrm = simd_normalize(normals[ia] * b.x + normals[ib] * b.y + normals[ic] * b.z)
            let uv = uvs[ia] * b.x + uvs[ib] * b.y + uvs[ic] * b.z
            for c in ctxs {
                if c.isSmile, o.excludeMouthInSmile, let mc = mouthUVCenter, simd_length(uv - mc) < 0.12 { continue }
                let pc = Geometry.transformPoint(c.w2c, pos)
                guard let px = c.K.project(pc) else { continue }
                guard px.x >= 1, px.y >= 1, px.x < Float(c.image.width - 1), px.y < Float(c.image.height - 1) else { continue }
                let viewDir = simd_normalize(c.camPos - pos)
                let cosv = simd_dot(nrm, viewDir)
                guard cosv > 0.3 else { continue }
                // 깊이 테스트
                if let d = c.depth, let Kd = c.Kd, let pd = Kd.project(pc), let captured = d.sample(pd) {
                    if abs(captured - (-pc.z)) > o.depthTolerance { continue }
                }
                guard var col = c.image.sample(px) else { continue }
                // 탈조명: 램버트 역보정 (slider 0 = 원본)
                if o.delight > 0, let L = c.light {
                    let shade = 0.35 + 0.65 * max(0, simd_dot(nrm, -L))
                    let inv = 1 / max(0.2, shade)
                    let f = 1 + (inv - 1) * o.delight
                    col = SIMD4(min(1, col.x * f), min(1, col.y * f), min(1, col.z * f), col.w)
                }
                // 가장자리 거리 가중치
                let ex = min(px.x, Float(c.image.width) - px.x) / Float(c.image.width), ey = min(px.y, Float(c.image.height) - px.y) / Float(c.image.height)
                let edge = min(1, min(ex, ey) / 0.08)
                let w = cosv * cosv * cosv * edge
                accum[idx] += SIMD3(col.x, col.y, col.z) * w
                wsum[idx] += w
            }
            if wsum[idx] > 0 { observed += 1 }
        }
        var albedo = RGBAImage(width: S, height: S, fill: SIMD4(0, 0, 0, 0))
        var mask = RGBAImage(width: S, height: S, fill: SIMD4(0, 0, 0, 255))
        for idx in 0..<(S * S) where wsum[idx] > 0 {
            let c = accum[idx] / wsum[idx]
            albedo[idx % S, idx / S] = SIMD4(UInt8(min(255, c.x * 255 + 0.5)), UInt8(min(255, c.y * 255 + 0.5)), UInt8(min(255, c.z * 255 + 0.5)), 255)
            mask[idx % S, idx / S] = SIMD4(255, 0, 0, 255)
        }
        // 대칭 복사: 미관측 텍셀 → 거울 정점 UV 로 샘플
        var mirrored = 0
        if o.mirrorFill, symmetryMap.count == positions.count {
            let src = albedo
            for idx in 0..<(S * S) where triID[idx] >= 0 && wsum[idx] <= 0 {
                let t3 = Int(triID[idx]) * 3
                let ids = [Int(indices[t3]), Int(indices[t3 + 1]), Int(indices[t3 + 2])]
                let b = bary[idx]
                var muv = SIMD2<Float>.zero
                var ok = true
                for (k, i) in ids.enumerated() {
                    let j = Int(symmetryMap[i])
                    guard j >= 0 else { ok = false; break }
                    muv += uvs[j] * [b.x, b.y, b.z][k]
                }
                guard ok else { continue }
                let px = SIMD2(muv.x * Float(S), (1 - muv.y) * Float(S))
                let xi = min(S - 1, max(0, Int(px.x))), yi = min(S - 1, max(0, Int(px.y)))
                let c = src[xi, yi]
                if c.w > 0 { albedo[idx % S, idx / S] = c; mask[idx % S, idx / S] = SIMD4(0, 255, 0, 255); mirrored += 1 }
            }
        }
        // 남은 빈 텍셀: 이웃 평균 확산(간단 pull-push 대용, 3회)
        var filled = 0
        for _ in 0..<3 {
            let src = albedo
            for y in 0..<S { for x in 0..<S where triID[y * S + x] >= 0 && src[x, y].w == 0 {
                var sum = SIMD3<Float>.zero; var n: Float = 0
                for dy in -2...2 { for dx in -2...2 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < S, yy < S else { continue }
                    let c = src[xx, yy]
                    if c.w > 0 { sum += SIMD3(Float(c.x), Float(c.y), Float(c.z)); n += 1 }
                } }
                if n > 0 {
                    let c = sum / n
                    albedo[x, y] = SIMD4(UInt8(c.x), UInt8(c.y), UInt8(c.z), 255)
                    if mask[x, y].x == 0 && mask[x, y].y == 0 { mask[x, y] = SIMD4(0, 0, 255, 255); filled += 1 }
                }
            } }
        }
        let q = TextureQuality(observedRatio: texels > 0 ? Float(observed) / Float(texels) : 0,
                               mirroredRatio: texels > 0 ? Float(mirrored) / Float(texels) : 0,
                               filledRatio: texels > 0 ? Float(filled) / Float(texels) : 0,
                               seamDelta: 0, buildSeconds: Date().timeIntervalSince(start))
        return TextureProjectionResult(albedo: albedo, mask: mask, quality: q)
    }

    /// 관측 영역 PSNR (dB) — 테스트용. 두 이미지는 같은 크기, `mask` 의 R 채널이 255 인 텍셀만.
    public static func psnr(_ a: RGBAImage, _ b: RGBAImage, mask: RGBAImage?) -> Float {
        guard a.width == b.width, a.height == b.height else { return .nan }
        var mse: Double = 0; var n = 0
        for y in 0..<a.height { for x in 0..<a.width {
            if let m = mask, m[x, y].x < 255 { continue }
            let ca = a[x, y], cb = b[x, y]
            for k in 0..<3 { let d = Double(Int(ca[k]) - Int(cb[k])); mse += d * d }
            n += 3
        } }
        guard n > 0, mse > 0 else { return 99 }
        return Float(10 * log10(255 * 255 / (mse / Double(n))))
    }
}
