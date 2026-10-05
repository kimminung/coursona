import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaTexture

/// M4 T-408: 합성 번들에서 알베도 ↔ 원본 텍스처 PSNR, 관측 비율, 접합 단차, 탈조명 0 = 원본, Metal 패리티.
@Suite("M4 텍스처 빌더", .serialized)
struct TextureBuilderTests {
    static let template = SyntheticTemplate.make()

    /// 대역 제한 알베도(`SyntheticAlbedo.smooth`)로 렌더한 5컷. `hardEdges` 면 M0 의 계단·주근깨 알베도.
    static func bundle(brightness: [ShotKind: Float] = [:], hardEdges: Bool = false, kinds: [ShotKind] = ShotKind.allCases) -> CaptureBundle {
        var o = SyntheticCaptureOptions()
        o.imageWidth = 1280; o.imageHeight = 960; o.depthWidth = 640; o.depthHeight = 480
        var b = SyntheticCapture.makeBundle(template: template, kinds: kinds, options: o) { u, v in hardEdges ? SyntheticAlbedo.color(u: u, v: v) : SyntheticAlbedo.smooth(u: u, v: v) }
        // 컷별 노출 차이 흉내 (접합 보정 테스트)
        for i in b.shots.indices {
            guard let k = brightness[b.shots[i].kind], var img = b.shots[i].image else { continue }
            for j in stride(from: 0, to: img.bytes.count, by: 4) {
                for c in 0..<3 { img.bytes[j + c] = UInt8(min(255, Float(img.bytes[j + c]) * k)) }
            }
            b.shots[i].image = img
        }
        return b
    }

    /// 면적 평균 정답 알베도 (텍셀을 n×n 으로 쪼개 평균) — 투영기도 footprint 를 적분하므로 같은 정의로 비교한다.
    static func truth(size: Int, samples n: Int, hardEdges: Bool = false) -> RGBAImage {
        var img = RGBAImage(width: size, height: size)
        for y in 0..<size { for x in 0..<size {
            var c = SIMD3<Float>.zero
            for sy in 0..<n { for sx in 0..<n {
                let u = (Float(x) + (Float(sx) + 0.5) / Float(n)) / Float(size), v = 1 - (Float(y) + (Float(sy) + 0.5) / Float(n)) / Float(size)
                c += hardEdges ? SyntheticAlbedo.color(u: u, v: v) : SyntheticAlbedo.smooth(u: u, v: v)
            } }
            c /= Float(n * n)
            img[x, y] = SIMD4(UInt8(c.x * 255 + 0.5), UInt8(c.y * 255 + 0.5), UInt8(c.z * 255 + 0.5), 255)
        } }
        return img
    }

    static func options(size: Int = 256, metal: Bool = false) -> TextureBuildOptions {
        var o = TextureBuildOptions()
        o.size = size; o.supersample = 3; o.preferMetal = metal; o.delight = 1
        return o
    }

    final class StageBox: @unchecked Sendable { var stages: [TextureStage: Double] = [:] }

    /// T-306 다시점: 희소(사진 폴백, 깊이 없음) 번들도 `FaceFitter.alignments` 가 정렬을 주면 TextureBuilder 가 돈다 —
    /// 전에는 희소 번들에 정렬이 전혀 없어 `noUsableShots` 로 텍스처를 건너뛰었다(AppModel.swift).
    @Test("희소(깊이 없음) 5컷도 정렬이 생기면 TextureBuilder 가 돌고 관측 비율이 바닥을 넘는다")
    func sparseTextureBuilds() throws {
        let t = Self.template
        let kinds: [ShotKind] = [.front, .left, .right, .up]
        let b = FitTests.sparseBundle(user: t.positions, template: t, kinds: kinds)
        #expect(b.shots.allSatisfy { $0.depth == nil } && b.meta.sparse)
        let id = try FaceFitter.fit(bundle: b, template: t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        #expect(Set(a.keys) == Set(kinds))
        let r = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: Self.options())
        print("희소 텍스처: \(r.summary)")
        #expect(r.quality.observedRatio > 0.1, "깊이 없는 희소 5컷도 얼굴 쪽은 관측돼야 한다 (관측 \(r.quality.observedRatio))")
    }

    @Test("합성 5컷 → 관측 영역 PSNR > 32 dB(대역 제한 알베도) · 관측 비율 > 70 % · 마스크가 메시 안을 다 덮는다")
    func psnrAndCoverage() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let box = StageBox()
        let r = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: Self.options()) { s, f in box.stages[s] = f }
        let truth = Self.truth(size: 256, samples: 3)
        let psnr = CPUTextureProjector.psnr(r.albedo, truth, mask: r.mask)
        print("M4 합성: \(r.summary) · PSNR \(psnr) dB · 단계 \(r.stageSeconds.map { String(format: "%.2f", $0) }) · 조명 \(r.lights.mapValues { String(format: "%@ f=%.2f", $0.source, $0.ambientFraction) })")
        #expect(psnr > 32, "PSNR \(psnr)")
        #expect(r.quality.observedRatio > 0.7)
        let stages = box.stages
        #expect(stages.count == TextureStage.allCases.count && stages.values.allSatisfy { $0 == 1 })
        // 참고: M0 의 계단·주근깨 알베도(1텍셀 점) 로는 에일리어싱 때문에 25 dB 급 — 투영기 한계가 아니라 측정 대상의 대역 문제
        let hard = Self.bundle(hardEdges: true)
        let rh = try TextureBuilder.build(bundle: hard, template: t, identity: id, alignments: FaceFitter.alignments(bundle: hard, template: t), options: Self.options())
        print(String(format: "M4 합성(계단 알베도, 정보): PSNR %.1f dB", CPUTextureProjector.psnr(rh.albedo, Self.truth(size: 256, samples: 3, hardEdges: true), mask: rh.mask)))
        // 메시 안 텍셀은 관측·대칭·채움 중 하나
        var insideUnfilled = 0, total = 0
        let raster = TexelRaster(render: t.makeRenderMesh(), size: 256)
        for y in 0..<256 { for x in 0..<256 where raster.inside(x: x, y: y) {
            total += 1
            let m = r.mask[x, y]
            if m.x < 128 && m.y < 128 && m.z < 128 { insideUnfilled += 1 }
        } }
        // 테스트 래스터(부표본 1)와 빌더(부표본 3)의 가장자리 확장이 달라 테두리 몇 텍셀은 어긋날 수 있다 → 0.5 % 미만
        #expect(Double(insideUnfilled) / Double(max(1, total)) < 0.005, "\(insideUnfilled)/\(total)")
        #expect(r.quality.filledRatio > 0.02)
    }

    @Test("대칭 복사: 정면+왼쪽 컷만 → 오른쪽 뺨이 거울 복사로 채워지고(G), 색이 왼쪽과 같다")
    func mirrorFill() throws {
        let t = Self.template
        let b = Self.bundle(kinds: [.front, .left])
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var o = Self.options(); o.skinFilter = false
        let r = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: o)
        var oNo = o; oNo.mirrorFill = false
        let rNo = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: oNo)
        print("대칭: \(r.summary) / 끔 \(rNo.summary)")
        #expect(r.quality.mirroredRatio > 0.03)
        #expect(rNo.quality.mirroredRatio == 0 && rNo.quality.filledRatio > r.quality.filledRatio)
        // 거울 복사된 텍셀은 정답과 가깝다 (대역 제한 알베도는 u 에 대해 거의 대칭 — sin 항만 ±0.03)
        let truth = Self.truth(size: 256, samples: 3)
        var err: Float = 0, nm: Float = 0
        for y in 0..<256 { for x in 0..<256 where r.mask[x, y].y > 127 {
            let c = r.albedo[x, y], d = truth[x, y]
            err += Float(abs(Int(c.x) - Int(d.x)) + abs(Int(c.y) - Int(d.y)) + abs(Int(c.z) - Int(d.z))) / 3; nm += 1
        } }
        print(String(format: "대칭 복사 텍셀 %d · 정답 대비 평균 오차 %.1f/255", Int(nm), err / max(1, nm)))
        #expect(nm > 0 && err / max(1, nm) < 30)
    }

    @Test("조명 추정: 합성 광원 방향과 15° 이내 (정면 컷)")
    func lightEstimate() throws {
        let t = Self.template
        var o = SyntheticCaptureOptions(); o.imageWidth = 640; o.imageHeight = 480; o.depthWidth = 320; o.depthHeight = 240
        let b = SyntheticCapture.makeBundle(template: t, options: o)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let shot = b.shot(.front)!
        let F = a[.front]!
        let M = F * shot.faceTransform.inverse * shot.cameraTransform
        let e = try #require(TextureLighting.estimate(shot: shot, template: t, faceToTemplate: F, cameraToTemplate: M))
        let truthToward = -Geometry.transformDirection(F * shot.faceTransform.inverse, o.lightDirection)
        let angle = acos(max(-1, min(1, simd_dot(e.towardLight, simd_normalize(truthToward))))) * 180 / .pi
        print(String(format: "조명 추정: 각도 오차 %.1f° · 대비 %.2f · 표본 %d", angle, e.contrast, e.samples))
        #expect(angle < 15)
        #expect(e.contrast > TextureLighting.minContrast)
    }

    @Test("접합 보정: 컷별 노출 ±10 % → 단차가 3/255 아래로, PSNR 유지")
    func seamCorrection() throws {
        let t = Self.template
        let b = Self.bundle(brightness: [.left: 1.12, .right: 0.9, .up: 1.08])
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var off = Self.options(); off.seamCorrection = false
        let r0 = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: off)
        let r1 = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: Self.options())
        let truth = Self.truth(size: 256, samples: 3)
        let p0 = CPUTextureProjector.psnr(r0.albedo, truth, mask: r0.mask), p1 = CPUTextureProjector.psnr(r1.albedo, truth, mask: r1.mask)
        print(String(format: "접합: 보정 전 단차 %.2f → 후 %.2f /255 · PSNR %.1f → %.1f dB", r1.seamDeltaBefore, r1.quality.seamDelta, p0, p1))
        #expect(r1.seamDeltaBefore > 3)
        #expect(r1.quality.seamDelta < 3)
        #expect(p1 >= p0 - 0.5)
    }

    @Test("탈조명 0 = 원본: 조명을 아예 안 쓸 때와 같은 이미지, 뺨 보정 1")
    func delightZeroIsIdentity() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var o = Self.options(); o.delight = 0; o.skinFilter = false
        let r = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: o)
        #expect(r.cheekGain == SIMD3(repeating: 1))
        // 조명 추정값을 바꿔도(= 다른 shade) 결과가 같아야 한다: 번들 조명 방향을 뒤집어 다시 빌드
        var b2 = b
        for i in b2.shots.indices { b2.shots[i].meta.light.primaryDirection = [0, 0, 1] }
        let r2 = try TextureBuilder.build(bundle: b2, template: t, identity: id, alignments: a, options: o)
        #expect(r.albedo.bytes == r2.albedo.bytes)
        // 강도 1 이면 다르다 (탈조명이 실제로 작동)
        var o1 = o; o1.delight = 1
        let r3 = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: o1)
        #expect(r3.albedo.bytes != r.albedo.bytes)
    }

    @Test("Metal 백엔드: CPU 와 256² 패리티 (평균 차 < 1.5/255, 관측 수 ±1 %)")
    func metalParity() throws {
        #if canImport(Metal)
        guard let gpu = MetalTextureBackend.shared else {
            print("Metal 없음 — 패리티 테스트 건너뜀"); return
        }
        let t = Self.template
        let b = Self.bundle(brightness: [.left: 1.1])
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var oc = Self.options(); oc.supersample = 2
        let cpu = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: oc)
        let gpuR = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: Self.options(metal: true).with { $0.supersample = 2 })
        #expect(gpuR.backend == "Metal", "\(gpuR.backend)")
        var sum = 0, n = 0, obsCPU = 0, obsGPU = 0, big = 0
        for y in 0..<256 { for x in 0..<256 {
            let mc = cpu.mask[x, y].x > 127, mg = gpuR.mask[x, y].x > 127
            if mc { obsCPU += 1 }; if mg { obsGPU += 1 }
            guard mc && mg else { continue }
            let c = cpu.albedo[x, y], g = gpuR.albedo[x, y]
            let d = abs(Int(c.x) - Int(g.x)) + abs(Int(c.y) - Int(g.y)) + abs(Int(c.z) - Int(g.z))
            sum += d; n += 3
            if d > 9 { big += 1 }
        } }
        let mean = Double(sum) / Double(max(1, n))
        print(String(format: "Metal 패리티 (%@): 평균 차 %.3f/255 · 3/255 넘는 텍셀 %d · 관측 CPU %d GPU %d · GPU %.2f s vs CPU %.2f s", gpu.name, mean, big, obsCPU, obsGPU, gpuR.quality.buildSeconds, cpu.quality.buildSeconds))
        #expect(mean < 1.5)
        #expect(abs(obsCPU - obsGPU) <= max(10, obsCPU / 100))
        #endif
    }
}

private extension TextureBuildOptions {
    func with(_ edit: (inout TextureBuildOptions) -> Void) -> TextureBuildOptions { var o = self; edit(&o); return o }
}
