//
//  CaptureTexturing.swift
//  CoursonaTexture
//
//  실제 캡처 번들 → 템플릿 UV 알베도 (M4 의 1차, CPU 참조 구현).
//
//  `CPUTextureProjector` 는 "모든 컷이 한 좌표계에 있다" 고 보고 월드 좌표에 투영한다(합성 캡처는 그렇다).
//  실제 캡처는 컷마다 머리 위치·방향이 달라 그대로 넣으면 전부 어긋난다. 그래서 각 컷의 카메라를 **템플릿 공간으로 옮겨서** 넘긴다:
//
//      원하는 변환  w2c' = cameraTransform⁻¹ · faceTransform · F⁻¹      (F = 얼굴 → 템플릿, `FaceFitter.alignments`)
//      투영기가 `cameraTransform.inverse` 를 쓰므로  cameraTransform' = F · faceTransform⁻¹ · cameraTransform
//
//  강체 변환이라 깊이(카메라로부터의 거리)와 법선 판정은 그대로 유효하다.
//

import Foundation
import simd
import CoursonaCore

public enum CaptureTexturing {
    public struct Result: Sendable {
        public var albedo: RGBAImage
        public var mask: RGBAImage
        public var quality: TextureQuality
        /// 실제로 투영에 쓴 컷
        public var usedShots: [ShotKind]
    }

    public enum TexturingError: Error, LocalizedError {
        case noUsableShots
        public var errorDescription: String? {
            switch self {
            case .noUsableShots: "텍스처를 만들 컷이 없습니다 (사진이 없거나 정렬에 실패했습니다)"
            }
        }
    }

    /// 캡처 컷의 카메라를 템플릿 공간으로 옮긴 복사본. `alignments` 에 없는 컷(정렬 실패)은 버린다.
    public static func shotsInTemplateSpace(_ shots: [CaptureShot], alignments: [ShotKind: simd_float4x4]) -> [CaptureShot] {
        shots.compactMap { shot in
            guard shot.image != nil, let F = alignments[shot.kind] else { return nil }
            var moved = shot
            moved.meta.cameraTransform = Matrix4Codable(F * shot.faceTransform.inverse * shot.cameraTransform)
            return moved
        }
    }

    /// 실기기 캡처용 기본 옵션. 합성 캡처보다 깊이 노이즈·피팅 오차가 커서 허용치를 넓힌다
    /// (1차 실기기: 0.015 m 로는 관측 24% 에 그쳤다).
    public static func deviceOptions(size: Int = 512) -> TextureProjectionOptions {
        var o = TextureProjectionOptions()
        o.size = size
        o.depthTolerance = 0.035
        return o
    }

    /// 번들 + 피팅 결과 → 알베도. `positions` 는 **피팅된 정점**(Identity.positions)을 넘긴다.
    /// - Parameter flattenUnobserved: 사진에 안 잡힌 영역(어깨·뒤통수)을 **관측 평균색**으로 평탄화한다.
    ///   투영기의 채움은 가까운 텍셀을 퍼뜨리는 방식이라 실제 캡처에서는 줄무늬·얼룩이 된다.
    public static func project(bundle: CaptureBundle, template t: BustTemplate, positions: [SIMD3<Float>],
                               alignments: [ShotKind: simd_float4x4],
                               options: TextureProjectionOptions = TextureProjectionOptions(),
                               flattenUnobserved: Bool = true) throws -> Result {
        let shots = shotsInTemplateSpace(bundle.shots, alignments: alignments)
        guard !shots.isEmpty else { throw TexturingError.noUsableShots }
        let pos = positions.count == t.positions.count ? positions : t.positions
        // **렌더 메시(코너 UV)** 로 투영한다. `t.uvs` 는 "정점당 첫 루프" 호환값이라 솔기 정점의 UV 가 틀리고,
        // 그대로 래스터화하면 솔기 삼각형이 UV 공간을 가로질러 늘어나 방사형 줄무늬가 된다(실기기에서 확인).
        let render = t.makeRenderMesh()
        let rPos = render.expand(pos)
        let rNormals = Geometry.vertexNormals(positions: rPos, indices: render.indices)
        let mouthUV = t.manifest.landmark(.lipUpperMid).flatMap { src -> SIMD2<Float>? in
            guard let i = render.sourceIndex.firstIndex(of: Int32(src)) else { return nil }
            return render.uvs[i]
        }
        // 대칭 맵은 원본 정점 기준이라 분할된 렌더 메시에는 그대로 쓸 수 없다 → 대칭 복사 대신 평탄화로 메운다.
        let r = CPUTextureProjector.project(positions: rPos, normals: rNormals, uvs: render.uvs, indices: render.indices,
                                            shots: shots, symmetryMap: [],
                                            mouthUVCenter: mouthUV, options: options)
        var albedo = r.albedo
        if flattenUnobserved { flattenFill(&albedo, mask: r.mask) }
        return Result(albedo: albedo, mask: r.mask, quality: r.quality, usedShots: shots.map(\.kind))
    }

    /// 상하 반전 (UV 세로축 규약 맞추기). **기본 경로에서는 쓰지 않는다 — 실기기 확정.**
    ///
    /// `SoftwareRasterizer.rasterizeUV` 는 `y = (1 − v)·S` 로 찍고, 이 템플릿의 얼굴 UV 는 v 가 작다
    /// (코끝 0.260 · 턱 0.050 · 입꼬리 0.190) → 얼굴이 알베도 이미지 **아래쪽**에 온다.
    /// RealityKit 이 그 UV 로 샘플링할 때도 같은 방향이라 **그대로 올려야 맞는다**.
    /// 뒤집으면 얼굴 색이 어깨 UV 로 내려간다(Vision Pro 실기기에서 확인). 템플릿 UV 규약이 바뀔 때를 위해 함수는 남겨 둔다.
    public static func flippedVertically(_ img: RGBAImage) -> RGBAImage {
        var out = img
        for y in 0..<img.height {
            let sy = img.height - 1 - y
            for x in 0..<img.width { out[x, y] = img[x, sy] }
        }
        return out
    }

    /// 마스크의 **채움 영역**(관측도 대칭도 아닌 곳)을 관측 평균색으로 덮는다.
    /// 관측 텍셀이 없으면 아무 것도 하지 않는다.
    public static func flattenFill(_ albedo: inout RGBAImage, mask: RGBAImage) {
        guard mask.width == albedo.width, mask.height == albedo.height else { return }
        var sum = SIMD3<Float>.zero
        var n: Float = 0
        for y in 0..<albedo.height {
            for x in 0..<albedo.width where mask[x, y].x > 127 {   // R = 관측
                let c = albedo[x, y]
                sum += SIMD3(Float(c.x), Float(c.y), Float(c.z))
                n += 1
            }
        }
        guard n > 0 else { return }
        let avg = sum / n
        let fill = SIMD4<UInt8>(UInt8(min(255, max(0, avg.x))), UInt8(min(255, max(0, avg.y))), UInt8(min(255, max(0, avg.z))), 255)
        for y in 0..<albedo.height {
            for x in 0..<albedo.width {
                let m = mask[x, y]
                if m.x <= 127 && m.y <= 127 { albedo[x, y] = fill }   // 관측도 대칭도 아니면 평탄화
            }
        }
    }
}
