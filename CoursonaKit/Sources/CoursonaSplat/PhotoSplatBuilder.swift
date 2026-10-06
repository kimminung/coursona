//
//  PhotoSplatBuilder.swift
//  CoursonaSplat
//
//  C9: 얼굴면 밖(두피·목·어깨) 가우시안 스플랫을 **메시 삼각형 지오메트리**가 아니라 **촬영 사진에서 직접** 뽑는다.
//  레퍼런스 앱 "소반"의 사진 기반 스플랫 방식을 코르소나 사정에 맞게 바꾼 것 — 소반은 깊이·3D 애셋이 없을 때
//  머리 타원체 + 몸통 반원기둥 analytic 근사로 사진 픽셀의 깊이를 추정하지만, 코르소나는 이미 피팅된 실제 3D
//  흉상 메시가 있으므로 그 메시를 **역투영**(카메라 광선이 메시 표면과 만나는 지점)해 훨씬 간단하고 정확하게
//  같은 결과를 얻는다 — `TextureBuilder.makeContexts` 가 자기 가림 판정에 쓰는 것과 같은
//  `SoftwareRasterizer.render` 호출이, 정확히 필요한 "사진 픽셀 → 3D 점" 역조회다.
//
//  `SplatBinder`(메시 삼각형 외접원 기반, `CoursonaSplat.swift`)는 그대로 둔다 — 기존 테스트·`BustEntity.applySplats`
//  가 참조하므로 삭제하지 않는다. `PersonaBuildPipeline` 의 호출부만 이쪽으로 바꾼다.
//
//  v1 범위(의도적으로 미룸, 계획 문서 참고):
//   - 전면 컷 1장만 쓴다 — 측면 보강은 v2.
//   - 메시가 덮는 픽셀만 스플랫을 둔다(두상 밖으로 삐져나온 머리카락·템플릿보다 넓은 어깨처럼 메시 밖인 픽셀은
//     스킵) — 소반의 analytic 폴백(타원체/원기둥)은 메시 역투영만으로 v1 범위가 충분히 커버돼 미뤘다.
//     이 범위 자체가 인물 마스크 역할을 겸한다(메시가 안 덮으면 애초에 후보가 안 됨) — 그래서 별도 Vision
//     인물 분할(PersonMatte) 의존 없이 v1을 구현할 수 있다.
//

import Foundation
import simd
import CoursonaCore
import CoursonaFace
import CoursonaTexture

public struct PhotoSplatOptions: Sendable {
    /// 목표/최대 스플랫 수(소반과 같은 식으로 격자 보폭을 역산한다).
    public var targetCount = 40_000
    public var maxCount = 60_000
    public var skinOpacity: Float = 0.95
    /// 얼굴 경계에 맞닿은 림(몇 라스터 픽셀 이내)은 이음매가 안 보이게 완전 불투명 + 카메라 반대쪽으로 살짝 밀어
    /// 얼굴 메시가 깊이 테스트에서 항상 이기게 한다.
    public var rimOpacity: Float = 1.0
    public var rimDistanceRasterPixels: Int = 2
    public var rimRecess: Float = 0.0015
    /// 바깥쪽(표면 법선 방향)으로 띄우는 거리(m) — 겹치는 스플랫끼리 z-파이팅 방지.
    public var normalOffset: Float = 0.0015
    /// 스케일 계수 + 상한(m). 상한은 이번 세션 내내 겪은 "외접원 폭주" 류 버그의 재발 방지용 안전장치 —
    /// 사진 기반이라 그 버그 자체는 구조적으로 없지만, 혹시 모를 극단적 깊이/경사 보정값을 방어적으로 자른다.
    public var scaleFactor: Float = 1.3
    public var maxScaleMeters: Float = 0.012
    /// 두피 삼각형(Scalp)은 기존 `SplatBinder`처럼 바깥쪽에 낮은 불투명도의 2차 겹을 하나 더 둬 숱 있는 느낌을 낸다.
    public var scalpLayerOffset: Float = 0.003
    public var scalpOuterOpacity: Float = 0.5
    /// 탈조명 강도 — 얼굴 텍스처(`TextureBuilder`, delight 0.5)와 이음매에서 밝기 차이가 안 나게 같은 값을 쓴다.
    public var delightStrength: Float = 0.5
    /// 전면 컷 한 장으로는 못 보는 비얼굴 삼각형(뒤통수·어깨 바깥쪽 등)을 채우는 보강 스플랫의 불투명도.
    /// 안 채우면 고스트(완전 투명)로 남아 반대쪽 메시가 비쳐 보이거나(뒤통수 "구멍") 배경과 같은 검정으로
    /// 보인다(실기기 회전 점검으로 확인) — 예전 `SplatBinder` 는 메시 전체를 항상 덮었으니 그 보장을 유지한다.
    public var fallbackOpacity: Float = 0.95
    /// 인물 마스크 임계(이 미만이면 그 픽셀은 사람이 아니라고 보고 사진 샘플을 안 쓴다).
    public var personAlphaThreshold: Float = 0.5
    /// 메시 밖(실루엣 바깥)인데 인물인 픽셀의 외삽 — 가장 가까운 메시 픽셀을 이 라스터 픽셀 반경 안에서 찾는다.
    /// Soban(`templateZ` 실루엣 밖 분기)처럼 거리에 비례해 뒤로 기울인다(옆 0.8 · 위아래 0.12 — 그 값 그대로).
    public var offMeshSearchRadius: Int = 40
    public var offMeshTiltLateral: Float = 0.8
    public var offMeshTiltVertical: Float = 0.12
    public var offMeshOpacity: Float = 0.9
    public init() {}
}

public enum PhotoSplatBuilder {
    /// `shot` 한 장(전면 컷)에서 얼굴면 밖 스플랫을 만든다. `faceToTemplate` 은 `FaceFitter.alignments(bundle:template:)`
    /// 가 그 컷에 대해 돌려주는 값(F) — 카메라 행렬은 `F * shot.faceTransform.inverse * shot.cameraTransform` 로
    /// 직접 구한다(`TextureBuilder.makeContexts`/`CaptureTexturing`과 같은 식 — `F` 단독은 카메라 포즈가 아니다).
    /// - personAlpha: 이미지 픽셀 좌표(좌상단 원점) → 0...1 인물 알파(`PersonMatte.sampler`). nil 이면 메시 실루엣만으로 간다(v1).
    /// - skinColor: 얼굴 텍스처의 피부색(`TextureBuildResult.skinColor`) — 두피가 아닌 비얼굴 보강 스플랫의 색.
    public static func build(shot: CaptureShot, faceToTemplate F: simd_float4x4, template t: BustTemplate, identity: Identity,
                             light: LightEstimateResult?, personAlpha: ((SIMD2<Float>) -> Float)? = nil, skinColor: SIMD3<Float>? = nil,
                             options o: PhotoSplatOptions = PhotoSplatOptions()) -> SplatBuildResult {
        guard let image = shot.image, image.width > 0, image.height > 0 else {
            return SplatBuildResult(records: [], faceTriangleCount: 0, nonFaceTriangleCount: 0)
        }

        // 메시 준비 — `SplatBinder.build` 와 같은 패턴(피팅 좌표 대입 → 캡 닫기 → 렌더 메시).
        var fittedForCaps = t
        if identity.positions.count == t.vertexCount { fittedForCaps.positions = identity.positions }
        let capResult = CapBuilder.addingCaps(to: fittedForCaps)
        let tc = capResult.template
        let render = tc.makeRenderMesh()
        let positions = render.expand(tc.positions)
        let normals = Geometry.vertexNormals(positions: positions, indices: render.indices)
        let triCount = render.indices.count / 3
        guard triCount > 0 else { return SplatBuildResult(records: [], faceTriangleCount: 0, nonFaceTriangleCount: 0) }

        func triAll(_ set: Set<Int>) -> [Bool] {
            (0..<triCount).map { tri in (0..<3).allSatisfy { set.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) } }
        }
        // `SplatBinder`/`TextureBuilder.isFaceTri` 와 같은 정의 — 얼굴면 = 패치 ∪ 눈꺼풀/입술 안쪽 ∪ 캡.
        let triPatch = triAll(Set(0..<tc.patchCount))
        let triLidInner = triAll(Set(tc.manifest.group(.lidInner)))
        let triLipInner = triAll(Set(tc.manifest.group(.lipInner)))
        let capTriRanges: [Range<Int>] = capResult.caps.map { $0.triangleIndexRange.lowerBound / 3 ..< $0.triangleIndexRange.upperBound / 3 }
        let isFaceTri: [Bool] = (0..<triCount).map { tri in
            triPatch[tri] || triLidInner[tri] || triLipInner[tri] || capTriRanges.contains { $0.contains(tri) }
        }
        let triScalp = triAll(Set(tc.manifest.group(.scalp)))

        // 카메라: `F` 는 얼굴 앵커 → 템플릿일 뿐 카메라 포즈가 아니다 — 반드시 이 합성으로 구한다.
        let M = F * shot.faceTransform.inverse * shot.cameraTransform
        let camPos = SIMD3(M.columns.3.x, M.columns.3.y, M.columns.3.z)

        // 절반 해상도로 래스터화(`TextureBuilder.makeContexts` 의 자기 가림 버퍼와 같은 관례) — 역투영에 충분하고 더 빠르다.
        let rw = max(64, image.width / 2), rh = max(64, image.height / 2)
        let K = shot.meta.intrinsics.scaled(toWidth: rw, height: rh)
        let camera = RenderCamera(intrinsics: K, transform: M)
        let raster = SoftwareRasterizer.render(positions: positions, normals: normals, uvs: render.uvs, indices: render.indices,
                                               camera: camera, width: rw, height: rh) { _, _, _ in .zero }

        let scaleX = Float(image.width) / Float(rw), scaleY = Float(image.height) / Float(rh)
        /// 라스터 픽셀 (x, y) 의 인물 알파(마스크 없으면 1).
        func person(_ x: Int, _ y: Int) -> Float {
            guard let personAlpha else { return 1 }
            return personAlpha(SIMD2((Float(x) + 0.5) * scaleX, (Float(y) + 0.5) * scaleY))
        }
        // 후보 = ① 얼굴면이 아니면서 메시가 덮는 픽셀(인물 마스크가 있으면 사람인 곳만) + ② 메시 밖인데 사람인 픽셀(외삽).
        // ②는 마스크가 있을 때만 — 마스크 없이 메시 밖을 채우면 배경이 그대로 들어온다.
        var eligible = 0
        for y in 0..<rh {
            for x in 0..<rw {
                let tri = Int(raster.triangleID[y * rw + x])
                if tri >= 0 {
                    if !isFaceTri[tri], person(x, y) >= o.personAlphaThreshold { eligible += 1 }
                } else if personAlpha != nil, person(x, y) >= o.personAlphaThreshold {
                    eligible += 1
                }
            }
        }
        // 후보가 0 이어도(마스크가 사람을 전혀 못 찾았거나 메시가 화면 밖) 여기서 끝내지 않는다 — 아래 보강 패스가
        // "비얼굴 전체를 덮는다" 는 보장을 책임지므로(테스트 `personMaskRejectsBackground` 가 이 회귀를 잡는다).
        // 소반과 같은 식으로 목표 개수에 맞춰 격자 보폭을 역산(제곱근 — 2D 격자이므로).
        let strideN = max(1, Int((Double(max(1, eligible)) / Double(o.targetCount)).squareRoot().rounded(.up)))

        let applyDelight = light.map { $0.contrast >= TextureLighting.minContrast } ?? false
        /// 사진 색 + 탈조명(얼굴 텍스처와 같은 강도).
        func photoColor(_ x: Int, _ y: Int, normal nrm: SIMD3<Float>) -> SIMD3<Float>? {
            let imgPx = SIMD2<Float>((Float(x) + 0.5) * scaleX, (Float(y) + 0.5) * scaleY)
            guard let sample = image.sample(imgPx) else { return nil }
            var color = SIMD3(sample.x, sample.y, sample.z)
            if applyDelight, let light {
                let shade = TextureLighting.shade(normal: nrm, light: light)
                let f = TextureLighting.delightFactor(shade: shade, strength: o.delightStrength)
                color = simd_min(SIMD3(repeating: 1), color * f)
            }
            return color
        }
        /// 메시 밖 픽셀에서 가장 가까운 메시 픽셀(링 탐색). (x, y, 거리²) — 반경 안에 없으면 nil.
        func nearestMeshPixel(_ x: Int, _ y: Int) -> (Int, Int, Float)? {
            let r = o.offMeshSearchRadius
            for ring in 1...max(1, r) {
                var best: (Int, Int, Float)? = nil
                let y0 = y - ring, y1 = y + ring, x0 = x - ring, x1 = x + ring
                func probe(_ px: Int, _ py: Int) {
                    guard px >= 0, py >= 0, px < rw, py < rh, raster.triangleID[py * rw + px] >= 0 else { return }
                    let d2 = Float((px - x) * (px - x) + (py - y) * (py - y))
                    if best == nil || d2 < best!.2 { best = (px, py, d2) }
                }
                for px in x0...x1 { probe(px, y0); probe(px, y1) }
                for py in (y0 + 1)..<y1 { probe(x0, py); probe(x1, py) }
                if let best { return best }
            }
            return nil
        }
        // 보강색 통계 — 사진이 닿은 두피(머리색)·그 외(피부색) 평균. 전역 평균 하나로 쓰면 배경·옷 색이 섞여 회색이 된다.
        var scalpSum = SIMD3<Float>.zero, scalpCount = 0
        var skinSum = SIMD3<Float>.zero, skinCount = 0

        /// 접평면 기저(법선 = 로컬 +Z)로 만든 회전 — `SplatBinder.tangentRotation` 과 같은 식, 월드 업을 기준 축으로.
        func tangentRotation(normal: SIMD3<Float>) -> simd_quatf {
            let upRef: SIMD3<Float> = abs(normal.y) > 0.95 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            var x = simd_cross(upRef, normal)
            let len = simd_length(x)
            x = len > 1e-9 ? x / len : SIMD3(1, 0, 0)
            let y = simd_cross(normal, x)
            return simd_quatf(simd_float3x3(columns: (x, y, normal)))
        }

        var records: [SplatRecord] = []
        records.reserveCapacity(min(o.maxCount, eligible / (strideN * strideN) + 1))
        var covered = [Bool](repeating: false, count: triCount)

        var y = strideN / 2
        while y < rh {
            var x = strideN / 2
            while x < rw {
                defer { x += strideN }
                let idx = y * rw + x
                let tri = Int(raster.triangleID[idx])
                let alpha = person(x, y)
                // ② 메시 밖 + 사람(마스크 있을 때만): 가장 가까운 메시 픽셀의 깊이를 빌려 거리에 비례해 뒤로 기울인다.
                if tri < 0 {
                    guard personAlpha != nil, alpha >= o.personAlphaThreshold, let near = nearestMeshPixel(x, y) else { continue }
                    let nearDepth = raster.depth[near.0, near.1]
                    guard nearDepth > 0 else { continue }
                    let pixelMeters = nearDepth / K.fx
                    let lateral = Float(abs(x - near.0)) * pixelMeters, vertical = Float(abs(y - near.1)) * pixelMeters
                    let depth = nearDepth + lateral * o.offMeshTiltLateral + vertical * o.offMeshTiltVertical
                    let pc = K.unproject(SIMD2(Float(x) + 0.5, Float(y) + 0.5), depth: depth)
                    let pos = Geometry.transformPoint(M, pc)
                    let nrm = simd_normalize(camPos - pos)
                    guard simd_length_squared(nrm) > 1e-12, let color = photoColor(x, y, normal: nrm) else { continue }
                    let footprint = depth / K.fx * Float(strideN)
                    let major = min(o.maxScaleMeters, footprint * o.scaleFactor * 1.2)
                    records.append(SplatRecord(position: pos, scale: SIMD3(major, major, major / 3), rotation: tangentRotation(normal: nrm),
                                               color: color, opacity: o.offMeshOpacity * min(1, alpha), triangle: -1, baryU: 0, baryV: 0, normalOffset: 0))
                    continue
                }
                guard !isFaceTri[tri], alpha >= o.personAlphaThreshold else { continue }

                let bary = raster.barycentric[idx]
                let ia = Int(render.indices[tri * 3]), ib = Int(render.indices[tri * 3 + 1]), ic = Int(render.indices[tri * 3 + 2])
                let pos = positions[ia] * bary.x + positions[ib] * bary.y + positions[ic] * bary.z
                var nrm = simd_normalize(normals[ia] * bary.x + normals[ib] * bary.y + normals[ic] * bary.z)
                let viewDir = simd_normalize(camPos - pos)   // 표면 → 카메라
                guard simd_length_squared(viewDir) > 1e-12 else { continue }
                if simd_dot(nrm, viewDir) < 0 { nrm = -nrm }   // 래스터라이저는 후면 컬링을 안 한다.

                // 림 판정: 주변 몇 라스터 픽셀 안에 얼굴면 픽셀이 있으면 이음매 경계.
                var isRim = false
                let r = o.rimDistanceRasterPixels
                outer: for dy in -r...r {
                    let ny = y + dy
                    guard ny >= 0, ny < rh else { continue }
                    for dx in -r...r {
                        let nx = x + dx
                        guard nx >= 0, nx < rw else { continue }
                        let nTri = Int(raster.triangleID[ny * rw + nx])
                        if nTri >= 0, isFaceTri[nTri] { isRim = true; break outer }
                    }
                }

                // 색: 같은 광선이 가리키는 원본 해상도 사진 픽셀(쌍선형) + 탈조명.
                guard let color = photoColor(x, y, normal: nrm) else { continue }
                if triScalp[tri] { scalpSum += color; scalpCount += 1 } else { skinSum += color; skinCount += 1 }

                // 스케일: 라스터 픽셀 보폭의 실제 크기(m) × 경사 보정(비스듬한 면은 더 크게 — 틈 방지), 상한 clamp.
                let depth = raster.depth[x, y]
                let footprint = depth > 0 ? depth / K.fx * Float(strideN) : 0.002
                let slope = 1 / max(0.3, abs(simd_dot(nrm, viewDir)))
                let major = min(o.maxScaleMeters, footprint * o.scaleFactor * slope)
                let scale = SIMD3<Float>(major, major, major / 3)
                let rot = tangentRotation(normal: nrm)

                let offset = isRim ? -o.rimRecess : o.normalOffset
                let shift = isRim ? -viewDir : nrm   // 림은 카메라 반대쪽(장면 안쪽)으로, 아니면 표면 바깥쪽으로.
                let opacity: Float = isRim ? o.rimOpacity : o.skinOpacity

                records.append(SplatRecord(position: pos + shift * offset, scale: scale, rotation: rot, color: color, opacity: opacity,
                                           triangle: Int32(tri), baryU: bary.x, baryV: bary.y, normalOffset: offset))
                covered[tri] = true

                // 두피: 기존 `SplatBinder` 처럼 바깥쪽에 낮은 불투명도의 2차 겹을 하나 더 둬 숱 있는 느낌을 낸다.
                if triScalp[tri] {
                    let outerOffset = o.normalOffset + o.scalpLayerOffset
                    records.append(SplatRecord(position: pos + nrm * outerOffset, scale: scale, rotation: rot, color: color,
                                               opacity: o.scalpOuterOpacity, triangle: Int32(tri), baryU: bary.x, baryV: bary.y, normalOffset: outerOffset))
                }
            }
            y += strideN
        }

        // 보강: 전면 컷이 못 보는 비얼굴 삼각형(뒤통수·옆통수·어깨 바깥쪽 등)은 위 루프에서 한 번도 안 채워졌다 —
        // 고스트(완전 투명)로 남겨 두면 반대쪽 메시가 비쳐 보이거나 배경과 같은 검정으로 보인다(실기기 회전
        // 점검에서 확인). 예전 `SplatBinder` 와 같은 식의 삼각형당 스플랫 1개로 채워 "비얼굴 전체를 덮는다" 는 보장만
        // 되살린다 — 사진이 닿은 곳의 디테일은 그대로 둔다.
        // 색은 **부위별**: 두피는 사진이 닿은 두피 평균(= 머리색), 그 외(목·어깨·귀)는 얼굴 텍스처의 피부색(`skinColor`)
        // 또는 사진이 닿은 비두피 평균. 전에는 전체 평균 하나를 썼는데 마스크 없이 들어온 배경·옷 색까지 섞여 회색
        // 마네킹처럼 보였다(실기기 2차 회전 점검).
        let hairColor: SIMD3<Float> = scalpCount >= 50 ? scalpSum / Float(scalpCount) : SIMD3(0.16, 0.12, 0.10)
        let bodyColor: SIMD3<Float> = skinColor ?? (skinCount >= 50 ? skinSum / Float(skinCount) : SIMD3(0.70, 0.55, 0.45))
        for tri in 0..<triCount where !isFaceTri[tri] && !covered[tri] {
            let fallbackColor = triScalp[tri] ? hairColor : bodyColor
            let ia = Int(render.indices[tri * 3]), ib = Int(render.indices[tri * 3 + 1]), ic = Int(render.indices[tri * 3 + 2])
            let p0 = positions[ia], p1 = positions[ib], p2 = positions[ic]
            let pos = (p0 + p1 + p2) / 3
            let nrm = simd_normalize(normals[ia] + normals[ib] + normals[ic])
            guard simd_length_squared(nrm) > 1e-12 else { continue }
            let lab = simd_length(p1 - p0), lbc = simd_length(p2 - p1), lca = simd_length(p0 - p2)
            let area = simd_length(simd_cross(p1 - p0, p2 - p0)) / 2
            // 외접원 반지름 clamp — 둔각 삼각형에서 폭주하던 그 버그(§circumR 코멘트 참고)의 재발 방지.
            let circumR = min(max(lab, lbc, lca), max(1e-5, (lab * lbc * lca) / max(1e-9, 4 * area)))
            let major = min(o.maxScaleMeters, circumR * o.scaleFactor)
            let scale = SIMD3<Float>(major, major, major / 3)
            records.append(SplatRecord(position: pos + nrm * o.normalOffset, scale: scale, rotation: tangentRotation(normal: nrm),
                                       color: fallbackColor, opacity: o.fallbackOpacity, triangle: Int32(tri), baryU: 1.0 / 3, baryV: 1.0 / 3,
                                       normalOffset: o.normalOffset))
        }

        if records.count > o.maxCount {
            let thinStride = Double(records.count) / Double(o.maxCount)
            var kept: [SplatRecord] = []; kept.reserveCapacity(o.maxCount)
            var i = 0.0
            while kept.count < o.maxCount, Int(i) < records.count { kept.append(records[Int(i)]); i += thinStride }
            records = kept
        }
        let nonFaceCount = (0..<triCount).filter { !isFaceTri[$0] }.count
        return SplatBuildResult(records: records, faceTriangleCount: triCount - nonFaceCount, nonFaceTriangleCount: nonFaceCount)
    }
}
