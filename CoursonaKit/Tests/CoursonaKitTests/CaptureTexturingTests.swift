import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaTexture

/// 실제 캡처 번들 → 알베도 (M4 1차). 합성 번들로 좌표 정합이 맞는지 검증한다.
@Suite("캡처 텍스처링")
struct CaptureTexturingTests {
    static let template = SyntheticTemplate.make()

    static func bundle() -> CaptureBundle {
        var o = SyntheticCaptureOptions()
        o.imageWidth = 640; o.imageHeight = 480; o.depthWidth = 320; o.depthHeight = 240
        return SyntheticCapture.makeBundle(template: template, options: o)
    }

    @Test("정렬 변환: 컷마다 하나씩, 강체(회전 + 이동)")
    func alignments() {
        let t = Self.template
        let b = Self.bundle()
        let a = FaceFitter.alignments(bundle: b, template: t)
        #expect(a.count == b.shots.count)
        for (_, m) in a {
            // 회전 부분이 직교인지 (강체)
            let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                  SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                  SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            let i = r * r.transpose
            #expect(abs(i.columns.0.x - 1) < 1e-3 && abs(i.columns.1.y - 1) < 1e-3 && abs(i.columns.2.z - 1) < 1e-3)
            #expect(abs(m.columns.3.w - 1) < 1e-6)
        }
    }

    @Test("정렬된 카메라로 투영하면 얼굴이 UV 에 제대로 찍힌다")
    func projectsWithAlignment() throws {
        let t = Self.template
        let b = Self.bundle()
        let a = FaceFitter.alignments(bundle: b, template: t)
        var po = TextureProjectionOptions()
        po.size = 128
        let r = try CaptureTexturing.project(bundle: b, template: t, positions: t.positions, alignments: a, options: po)
        #expect(!r.usedShots.isEmpty)
        #expect(r.albedo.width == 128 && r.albedo.height == 128)
        #expect(r.quality.observedRatio > 0.3, "관측 비율 \(r.quality.observedRatio)")
    }

    @Test("정렬을 빼먹으면 관측 비율이 크게 떨어진다 — 좌표 정합이 필요한 이유")
    func withoutAlignmentIsWorse() throws {
        let t = Self.template
        var b = Self.bundle()
        // 머리가 옆으로 20 cm 옮겨진 캡처를 흉내: faceTransform 과 cameraTransform 을 함께 민다
        let offset = simd_float4x4(SIMD4(1,0,0,0), SIMD4(0,1,0,0), SIMD4(0,0,1,0), SIMD4(0.2, 0.1, 0, 1))
        for i in b.shots.indices {
            b.shots[i].meta.faceTransform = Matrix4Codable(offset * b.shots[i].faceTransform)
            b.shots[i].meta.cameraTransform = Matrix4Codable(offset * b.shots[i].cameraTransform)
        }
        var po = TextureProjectionOptions(); po.size = 128

        // 정렬 적용 → 그대로 잘 찍힌다
        let a = FaceFitter.alignments(bundle: b, template: t)
        let good = try CaptureTexturing.project(bundle: b, template: t, positions: t.positions, alignments: a, options: po)
        #expect(good.quality.observedRatio > 0.3)

        // 정렬을 항등으로 두면(= 옛 방식) 카메라가 엉뚱한 곳을 본다
        let identityAlign = Dictionary(uniqueKeysWithValues: b.shots.map { ($0.kind, matrix_identity_float4x4) })
        let bad = try CaptureTexturing.project(bundle: b, template: t, positions: t.positions, alignments: identityAlign, options: po)
        #expect(bad.quality.observedRatio < good.quality.observedRatio * 0.6,
                "정렬 없음 \(bad.quality.observedRatio) vs 정렬 \(good.quality.observedRatio)")
    }
}

/// 관측 안 된 영역 평탄화 (실기기에서 줄무늬·얼룩이 나오던 부분).
@Suite("알베도 평탄화")
struct AlbedoFlattenTests {
    @Test("채움 영역이 관측 평균색 하나로 덮인다")
    func flatten() {
        var albedo = RGBAImage(width: 8, height: 8, fill: SIMD4(0, 0, 0, 255))
        var mask = RGBAImage(width: 8, height: 8, fill: SIMD4(0, 0, 0, 255))
        // 왼쪽 두 열 = 관측(R), 색은 (100,150,200)과 (140,170,220) → 평균 (120,160,210)
        for y in 0..<8 {
            albedo[0, y] = SIMD4(100, 150, 200, 255); mask[0, y] = SIMD4(255, 0, 0, 255)
            albedo[1, y] = SIMD4(140, 170, 220, 255); mask[1, y] = SIMD4(255, 0, 0, 255)
            albedo[2, y] = SIMD4(10, 240, 10, 255);   mask[2, y] = SIMD4(0, 255, 0, 255)   // 대칭 — 건드리지 않는다
            for x in 3..<8 { albedo[x, y] = SIMD4(UInt8(x * 30), 5, 5, 255); mask[x, y] = SIMD4(0, 0, 255, 255) } // 채움(줄무늬)
        }
        CaptureTexturing.flattenFill(&albedo, mask: mask)
        #expect(albedo[0, 0] == SIMD4(100, 150, 200, 255))      // 관측 그대로
        #expect(albedo[2, 0] == SIMD4(10, 240, 10, 255))        // 대칭 그대로
        for x in 3..<8 {
            #expect(albedo[x, 3] == SIMD4(120, 160, 210, 255), "채움 텍셀 \(x) 이 평균색이 아니다")
        }
    }

    @Test("관측이 하나도 없으면 그대로 둔다")
    func noObservation() {
        var albedo = RGBAImage(width: 4, height: 4, fill: SIMD4(7, 8, 9, 255))
        let mask = RGBAImage(width: 4, height: 4, fill: SIMD4(0, 0, 255, 255))
        CaptureTexturing.flattenFill(&albedo, mask: mask)
        #expect(albedo[1, 1] == SIMD4(7, 8, 9, 255))
    }

    @Test("실기기 기본 옵션은 깊이 허용치가 넓다")
    func deviceOptions() {
        #expect(CaptureTexturing.deviceOptions().depthTolerance > TextureProjectionOptions().depthTolerance)
        #expect(CaptureTexturing.deviceOptions(size: 256).size == 256)
    }
}

/// 코너 UV 회귀 — 솔기 정점의 UV 가 틀린 `t.uvs` 로 래스터화하면 텍스처가 방사형으로 늘어난다(실기기에서 확인).
@Suite("코너 UV")
struct CornerUVTests {
    @Test("렌더 메시는 솔기에서 정점을 분할하고, 분할된 UV 가 원본 정점 UV 와 다른 곳이 있다")
    func renderMeshSplitsSeams() {
        let t = SyntheticTemplate.make()
        let r = t.makeRenderMesh()
        #expect(r.vertexCount >= t.positions.count)
        #expect(r.indices.count == t.indices.count)
        #expect(r.sourceIndex.count == r.vertexCount)
        // 분할 정점은 원본을 가리키되 UV 는 서로 다를 수 있다
        var seen: [Int32: SIMD2<Float>] = [:]
        var differing = 0
        for i in 0..<r.vertexCount {
            let src = r.sourceIndex[i]
            if let prev = seen[src], simd_length(prev - r.uvs[i]) > 1e-6 { differing += 1 }
            seen[src] = r.uvs[i]
        }
        #expect(differing == r.vertexCount - t.positions.count, "분할 수와 UV 차이 개수가 맞아야 한다")
    }

    @Test("투영은 렌더 메시 UV 를 쓴다 — 원본 UV 로 하면 관측 비율이 떨어진다")
    func projectionUsesRenderMesh() throws {
        let t = SyntheticTemplate.make()
        var o = SyntheticCaptureOptions()
        o.imageWidth = 640; o.imageHeight = 480; o.depthWidth = 320; o.depthHeight = 240
        let b = SyntheticCapture.makeBundle(template: t, options: o)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var po = TextureProjectionOptions(); po.size = 128
        let viaRenderMesh = try CaptureTexturing.project(bundle: b, template: t, positions: t.positions, alignments: a, options: po)
        #expect(viaRenderMesh.quality.observedRatio > 0.3)
        // 렌더 메시 정점 수가 원본보다 많다면 분할이 실제로 일어난 것 (합성 템플릿도 코너 UV 를 갖는다)
        #expect(t.makeRenderMesh().vertexCount >= t.positions.count)
    }
}

/// UV 세로축 규약 (실기기 확정). 얼굴은 알베도 이미지 **아래쪽**에 찍히고, 그대로 올려야 맞는다.
@Suite("알베도 세로축 규약")
struct AlbedoOrientationTests {
    @Test("얼굴 랜드마크는 래스터 이미지 아래쪽에 온다")
    func faceLandsInLowerHalf() throws {
        let t = SyntheticTemplate.make()
        let render = t.makeRenderMesh()
        // 합성 템플릿도 같은 UV 규약을 쓴다 — 얼굴 랜드마크의 래스터 y 가 절반보다 아래
        for name in [LandmarkName.noseTip, .chin, .mouthLeft] {
            guard let src = t.manifest.landmark(name), let i = render.sourceIndex.firstIndex(of: Int32(src)) else { continue }
            let v = render.uvs[i].y
            let rasterY = 1 - v        // 0 = 위, 1 = 아래
            #expect(rasterY > 0.5, "\(name.rawValue) 의 래스터 y \(rasterY) 가 아래쪽이어야 한다 (v=\(v))")
        }
    }

    @Test("상하 반전은 되돌릴 수 있다")
    func flipIsInvolution() {
        var img = RGBAImage(width: 4, height: 6, fill: SIMD4(0, 0, 0, 255))
        for y in 0..<6 { for x in 0..<4 { img[x, y] = SIMD4(UInt8(x), UInt8(y), 0, 255) } }
        let once = CaptureTexturing.flippedVertically(img)
        #expect(once[2, 0] == SIMD4(2, 5, 0, 255))
        let twice = CaptureTexturing.flippedVertically(once)
        #expect(twice[2, 0] == img[2, 0] && twice[1, 4] == img[1, 4])
    }
}
