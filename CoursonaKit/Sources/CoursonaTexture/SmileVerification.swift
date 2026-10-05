//
//  SmileVerification.swift
//  CoursonaTexture
//
//  T-308 미소 컷 검증 렌더: 피팅된 흉상에 **미소 컷의 ARKit 가중치를 그대로** 넣어 그 컷의 카메라(템플릿 공간으로 옮긴 것)로 렌더하고
//  사진과 나란히 놓는다 — 피팅·델타 보정이 맞으면 입꼬리·눈 모양이 사진과 겹친다(TechPRD §6.8 표정 검증). CPU 래스터라이저(참조 구현).
//  카메라 이동은 CaptureTexturing 과 같다: cameraTransform' = F · faceTransform⁻¹ · cameraTransform.
//

import Foundation
import simd
import CoursonaCore

public enum SmileVerification {
    public struct Result: Sendable {
        /// 사진 (렌더와 같은 크기로 축소)
        public var photo: RGBAImage
        /// 같은 카메라로 그린 흉상
        public var render: RGBAImage
        /// 둘을 가로로 붙인 것 (사진 | 렌더)
        public var sideBySide: RGBAImage
        /// 쓴 가중치 합 (중립도) · 상위 셰이프
        public var weightSum: Float
        public var topShapes: [(ArkitShape, Float)]
        public var kind: ShotKind
    }

    /// 미소 컷(없으면 정면 컷)으로 검증 이미지. 사진이 없거나 정렬이 없으면 nil.
    /// - Parameters:
    ///   - albedo: 투영한 알베도(래스터 규약: v=0 이 아래). nil 이면 기본 살색.
    ///   - width: 출력 가로 픽셀 (세로는 사진 비율).
    public static func make(bundle: CaptureBundle, template t: BustTemplate, identity: Identity,
                            alignments: [ShotKind: simd_float4x4], albedo: RGBAImage?, width: Int = 360) -> Result? {
        guard let shot = bundle.shot(.smile) ?? bundle.shot(.front), let img = shot.image, let F = alignments[shot.kind] else { return nil }
        let w = max(32, width)
        let h = max(32, Int((Float(img.height) / Float(max(1, img.width)) * Float(w)).rounded()))

        // 변형 정점 (렌더 메시 = 코너 UV 분할)
        let render = t.makeRenderMesh()
        let src = identity.positions.count == t.vertexCount ? identity.positions : t.positions
        var deformed = src
        let weights = shot.meta.blendShapes
        for (shape, d) in identity.runtimeDeltas(template: t) {
            let wv = weights[shape]
            guard wv > 1e-4, d.count == deformed.count else { continue }
            for i in deformed.indices { deformed[i] += d[i] * wv }
        }
        let rPos = render.expand(deformed)
        let rNrm = Geometry.vertexNormals(positions: rPos, indices: render.indices)

        // 카메라 → 템플릿 공간
        let camT = F * shot.faceTransform.inverse * shot.cameraTransform
        let cam = RenderCamera(intrinsics: shot.meta.intrinsics.scaled(toWidth: img.width, height: img.height), transform: camT)
        // 광원: 캡처 조명 방향(월드) → 템플릿. 없으면 카메라에서 비춘다.
        var L = -simd_normalize(SIMD3(camT.columns.2.x, camT.columns.2.y, camT.columns.2.z))   // 카메라 전방 = −Z 열의 반대
        if let pd = shot.meta.light.primaryDirection, pd.count == 3 {
            let dirWorld = SIMD3<Float>(pd[0], pd[1], pd[2])
            let toTemplate = F * shot.faceTransform.inverse
            let dt = Geometry.transformDirection(toTemplate, dirWorld)
            if simd_length_squared(dt) > 1e-8 { L = simd_normalize(dt) }
        }
        let skin = SIMD3<Float>(0.86, 0.68, 0.58)
        let S = Float(albedo?.width ?? 1)
        let out = SoftwareRasterizer.render(positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices,
                                            camera: cam, width: w, height: h) { uv, n, _ in
            var base = skin
            if let a = albedo, let c = a.sample(SIMD2(uv.x * S, (1 - uv.y) * S)) { base = SIMD3(c.x, c.y, c.z) }
            let shade = 0.35 + 0.65 * max(0, simd_dot(n, -L))
            return base * shade
        }
        let photo = img.resampled(width: w, height: h)
        var side = RGBAImage(width: w * 2 + 4, height: h, fill: SIMD4(0, 0, 0, 255))
        for y in 0..<h {
            for x in 0..<w { side[x, y] = photo[x, y]; side[x + w + 4, y] = out.color[x, y] }
        }
        return Result(photo: photo, render: out.color, sideBySide: side, weightSum: weights.sum,
                      topShapes: weights.topContributors(3), kind: shot.kind)
    }
}

public extension RGBAImage {
    /// 쌍선형 리샘플 (축소·확대).
    func resampled(width w: Int, height h: Int) -> RGBAImage {
        guard w > 0, h > 0 else { return self }
        if w == width && h == height { return self }
        var out = RGBAImage(width: w, height: h, fill: SIMD4(0, 0, 0, 255))
        let sx = Float(width) / Float(w), sy = Float(height) / Float(h)
        for y in 0..<h {
            for x in 0..<w {
                let p = SIMD2((Float(x) + 0.5) * sx, (Float(y) + 0.5) * sy)
                if let c = sample(p) {
                    out[x, y] = SIMD4(UInt8(min(255, c.x * 255 + 0.5)), UInt8(min(255, c.y * 255 + 0.5)), UInt8(min(255, c.z * 255 + 0.5)), 255)
                } else {
                    let xi = min(width - 1, max(0, Int(p.x))), yi = min(height - 1, max(0, Int(p.y)))
                    out[x, y] = self[xi, yi]
                }
            }
        }
        return out
    }
}
