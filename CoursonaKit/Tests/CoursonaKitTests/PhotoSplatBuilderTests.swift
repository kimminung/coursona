import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaFace
@testable import CoursonaTexture
@testable import CoursonaSplat

/// C9: `PhotoSplatBuilder` — 얼굴면 밖 스플랫을 사진에서 직접 뽑는다(메시 삼각형 외접원 기반 `SplatBinder` 대체).
@Suite("사진 기반 스플랫 (C9)")
struct PhotoSplatBuilderTests {
    static let template = SyntheticTemplate.make()

    static func bundle() -> CaptureBundle {
        var o = SyntheticCaptureOptions()
        o.imageWidth = 640; o.imageHeight = 480; o.depthWidth = 320; o.depthHeight = 240
        return SyntheticCapture.makeBundle(template: template, options: o) { u, v in SyntheticAlbedo.smooth(u: u, v: v) }
    }

    /// `PhotoSplatBuilder` 내부와 똑같은 방식으로 "얼굴면 삼각형" 집합을 다시 구한다 — 결과 스플랫이 그 위에
    /// 하나도 없는지 바깥에서 검증하기 위함(`SplatBinder`/`TextureBuilder.isFaceTri` 와 같은 정의).
    static func faceTriangles(template t: BustTemplate, identity: Identity) -> Set<Int32> {
        var fittedForCaps = t
        if identity.positions.count == t.vertexCount { fittedForCaps.positions = identity.positions }
        let capResult = CapBuilder.addingCaps(to: fittedForCaps)
        let tc = capResult.template
        let render = tc.makeRenderMesh()
        let triCount = render.indices.count / 3
        func triAll(_ set: Set<Int>) -> [Bool] {
            (0..<triCount).map { tri in (0..<3).allSatisfy { set.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) } }
        }
        let triPatch = triAll(Set(0..<tc.patchCount))
        let triLidInner = triAll(Set(tc.manifest.group(.lidInner)))
        let triLipInner = triAll(Set(tc.manifest.group(.lipInner)))
        let capTriRanges: [Range<Int>] = capResult.caps.map { $0.triangleIndexRange.lowerBound / 3 ..< $0.triangleIndexRange.upperBound / 3 }
        var out = Set<Int32>()
        for tri in 0..<triCount where triPatch[tri] || triLidInner[tri] || triLipInner[tri] || capTriRanges.contains(where: { $0.contains(tri) }) {
            out.insert(Int32(tri))
        }
        return out
    }

    @Test("정면 컷으로 스플랫을 만들면 결과가 비어 있지 않다")
    func producesSplats() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let front = try #require(b.shot(.front))
        let F = try #require(a[.front])
        let r = PhotoSplatBuilder.build(shot: front, faceToTemplate: F, template: t, identity: id, light: nil)
        #expect(!r.records.isEmpty, "합성 번들(정면 컷 있음)인데 스플랫이 하나도 안 나옴")
    }

    @Test("얼굴면 삼각형 위에는 스플랫이 없다(이중상 방지)")
    func noSplatOnFaceTriangle() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let front = try #require(b.shot(.front))
        let F = try #require(a[.front])
        let r = PhotoSplatBuilder.build(shot: front, faceToTemplate: F, template: t, identity: id, light: nil)
        let faceTris = Self.faceTriangles(template: t, identity: id)
        let onFace = r.records.filter { $0.triangle >= 0 && faceTris.contains($0.triangle) }
        #expect(onFace.isEmpty, "\(onFace.count)개 스플랫이 얼굴면 삼각형 위에 있음 — 텍스처 입은 얼굴과 이중상이 생긴다")
    }

    @Test("스케일 상한을 넘는 스플랫이 없다(외접원 폭주류 회귀 방지)")
    func scaleIsClamped() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let front = try #require(b.shot(.front))
        let F = try #require(a[.front])
        let options = PhotoSplatOptions()
        let r = PhotoSplatBuilder.build(shot: front, faceToTemplate: F, template: t, identity: id, light: nil, options: options)
        let maxMajor = r.records.map { $0.scale.x }.max() ?? 0
        #expect(maxMajor <= options.maxScaleMeters + 1e-6, "스플랫 스케일이 상한(\(options.maxScaleMeters))을 넘음: \(maxMajor)")
    }

    @Test("전면 컷이 못 보는 비얼굴 삼각형(뒤통수 등)도 보강 스플랫으로 덮인다 — 실기기 회전 점검에서 발견한 '투명 구멍' 회귀 방지")
    func coversTrianglesOutsideFrontView() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let front = try #require(b.shot(.front))
        let F = try #require(a[.front])
        let r = PhotoSplatBuilder.build(shot: front, faceToTemplate: F, template: t, identity: id, light: nil)
        let faceTris = Self.faceTriangles(template: t, identity: id)
        var covered = Set<Int32>()
        for rec in r.records where rec.triangle >= 0 { covered.insert(rec.triangle) }
        var fittedForCaps = t
        if id.positions.count == t.vertexCount { fittedForCaps.positions = id.positions }
        let capResult = CapBuilder.addingCaps(to: fittedForCaps)
        let triCount = capResult.template.makeRenderMesh().indices.count / 3
        let uncovered = (0..<triCount).filter { !faceTris.contains(Int32($0)) && !covered.contains(Int32($0)) }
        #expect(uncovered.isEmpty, "\(uncovered.count)개 비얼굴 삼각형이 스플랫 없이 비어 있음(고스트로 남아 반대쪽이 비치거나 검게 보임) — 보강 패스가 빠졌을 수 있다")
    }

    @Test("인물 마스크 0 인 픽셀은 사진 스플랫이 안 생기고(배경 유입 차단), 메시 전체는 보강으로 여전히 덮인다")
    func personMaskRejectsBackground() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let front = try #require(b.shot(.front))
        let F = try #require(a[.front])
        let withPhoto = PhotoSplatBuilder.build(shot: front, faceToTemplate: F, template: t, identity: id, light: nil)
        // 전부 "사람 아님" — 사진 샘플(triangle ≥ 0, 보강 아님)은 0개, 보강 스플랫만 남아야 한다.
        let masked = PhotoSplatBuilder.build(shot: front, faceToTemplate: F, template: t, identity: id, light: nil, personAlpha: { _ in 0 })
        #expect(masked.records.count < withPhoto.records.count, "마스크가 0 인데 스플랫 수가 줄지 않음 — 마스크가 무시되고 있다")
        #expect(!masked.records.isEmpty, "마스크가 0 이어도 보강 패스는 비얼굴 삼각형을 덮어야 한다")
        #expect(masked.records.allSatisfy { $0.triangle >= 0 }, "마스크 0 에서는 메시 밖 외삽 스플랫(triangle -1)이 생기면 안 된다")
    }

    @Test("메시 밖인데 인물인 픽셀은 외삽 스플랫(triangle -1)으로 살아나고, 메시 가까이에 붙는다")
    func offMeshPersonPixelsAreExtrapolated() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let front = try #require(b.shot(.front))
        let F = try #require(a[.front])
        // 전부 "사람" — 메시 실루엣 밖(합성 번들의 배경)도 사람으로 보게 해 외삽 분기가 돌게 한다.
        let r = PhotoSplatBuilder.build(shot: front, faceToTemplate: F, template: t, identity: id, light: nil, personAlpha: { _ in 1 })
        let off = r.records.filter { $0.triangle < 0 }
        #expect(!off.isEmpty, "메시 밖 인물 픽셀이 있는데 외삽 스플랫이 하나도 없음")
        // 외삽점은 메시 정점 범위를 크게 벗어나지 않아야 한다(가까운 메시 깊이에서 최대 몇 cm 뒤로만 기운다).
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in id.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let margin: Float = 0.15
        let outliers = off.filter { any($0.position .< (lo - margin)) || any($0.position .> (hi + margin)) }
        #expect(outliers.count < off.count / 20, "외삽 스플랫 \(outliers.count)/\(off.count)개가 메시 범위 ±15 cm 를 벗어남 — 깊이 외삽 또는 역투영 행렬이 틀렸을 수 있다")
    }

    @Test("정렬이 없으면 빈 결과 대신 호출자가 안전하게 건너뛸 수 있다 — 전면 컷 자체가 없을 때")
    func handlesMissingImageGracefully() throws {
        let t = Self.template
        let id = Identity.fromTemplate(t)
        var shot = try #require(Self.bundle().shot(.front))
        shot.image = nil
        let r = PhotoSplatBuilder.build(shot: shot, faceToTemplate: matrix_identity_float4x4, template: t, identity: id, light: nil)
        #expect(r.records.isEmpty)
    }
}
