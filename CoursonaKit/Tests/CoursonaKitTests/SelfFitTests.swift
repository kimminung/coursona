import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaTexture
@testable import CoursonaIO

@Suite("T-009 합성 번들 · 셀프 피팅", .serialized)
struct SelfFitTests {
    static let template = SyntheticTemplate.make()

    @Test("합성 템플릿 구조가 계약을 따른다")
    func templateStructure() {
        let t = Self.template
        #expect(t.patchCount == 1220)
        #expect(t.vertexCount > 5000)
        #expect(t.shapeDeltas.count == 52)
        #expect(t.manifest.symmetryMap.count == t.vertexCount)
        #expect(!t.manifest.group(.scalp).isEmpty && !t.manifest.group(.neck).isEmpty && !t.manifest.group(.shoulders).isEmpty)
        #expect(t.manifest.group(.arkitFace).count == 1220)
        // 대칭 맵: 미러의 미러 = 자신, x 부호 반대
        for i in stride(from: 0, to: t.vertexCount, by: 97) {
            let j = Int(t.manifest.symmetryMap[i])
            #expect(Int(t.manifest.symmetryMap[j]) == i)
            #expect(abs(t.positions[i].x + t.positions[j].x) < 1e-4)
        }
        // 해시 결정적
        #expect(SyntheticTemplate.make().manifest.patchTriangleHash == t.manifest.patchTriangleHash)
        // 눈 간격 0.064 근처
        let m = t.manifest
        let cL = (t.positions[m.landmark(.eyeLeftOuter)!] + t.positions[m.landmark(.eyeLeftInner)!]) / 2
        let cR = (t.positions[m.landmark(.eyeRightOuter)!] + t.positions[m.landmark(.eyeRightInner)!]) / 2
        #expect(abs(simd_length(cL - cR) - 0.064) < 0.008, "눈 간격 \(simd_length(cL - cR))")
    }

    @Test("템플릿 자체 셀프 피팅 RMS < 0.2 mm")
    func selfFitIdentity() throws {
        let t = Self.template
        var opt = SyntheticCaptureOptions()
        opt.imageWidth = 320; opt.imageHeight = 240; opt.depthWidth = 320; opt.depthHeight = 240
        let bundle = SyntheticCapture.makeBundle(template: t, kinds: [.front, .left, .right, .up, .smile], options: opt)
        #expect(bundle.shots.count == 5)
        let id = try FaceFitter.fit(bundle: bundle, template: t)
        let rmsAll = Geometry.rms(id.positions, t.positions)
        let rmsPatch = Geometry.rms(Array(id.positions[0..<1220]), Array(t.positions[0..<1220]))
        print("셀프 피팅: 패치 RMS \(rmsPatch * 1000) mm · 전체 RMS \(rmsAll * 1000) mm · s=\(id.scale) · λ=\(id.quality!.rbfLambda) · 피벗비 \(id.quality!.rbfPivotRatio)")
        #expect(rmsPatch < 0.0002)
        #expect(rmsAll < 0.0002)
        #expect(abs(id.scale - 1) < 0.002)
        #expect(id.quality!.patchRMS < 0.0002)
    }

    @Test("섭동한 사용자(스케일 1.05·코·턱·광대·비대칭) 피팅: 패치 형상 정확, 두상 전파 오차 보고")
    func selfFitPerturbed() throws {
        let t = Self.template
        let user = SyntheticTemplate.perturbed(t, .sample)
        var opt = SyntheticCaptureOptions()
        opt.imageWidth = 320; opt.imageHeight = 240; opt.depthWidth = 320; opt.depthHeight = 240
        let bundle = SyntheticCapture.makeBundle(template: t, userPositions: user, options: opt)
        let id = try FaceFitter.fit(bundle: bundle, template: t)
        // 피팅 결과는 "눈 중점 = 템플릿 눈 중점" 규약으로 놓이므로(흉상 공간 절대 위치는 규약), 정답과는 강체(스케일 없음) 정렬 후 형상만 비교한다.
        let fittedPatch = Array(id.positions[0..<1220]), truthPatch = Array(user[0..<1220])
        let R = Procrustes.fit(source: fittedPatch, target: truthPatch, allowScale: false)!
        let alignedAll = id.positions.map { R.apply($0) }
        let rmsPatch = Geometry.rms(Array(alignedAll[0..<1220]), truthPatch)
        let rawOffset = Geometry.rms(fittedPatch, truthPatch)
        print("섭동 피팅: 패치 형상 RMS \(rmsPatch * 1000) mm (정렬 전 \(rawOffset * 1000) mm) · s=\(id.scale) · 회전 \(R.rotation.angle * 180 / .pi)°")
        #expect(rmsPatch < 0.0002, "패치 RMS \(rmsPatch)")
        #expect(abs(id.scale - 1.05) < 0.03, "s=\(id.scale)")   // 광대·비대칭 섭동이 눈 꼬리를 밀어 s 는 1.05 보다 조금 크다
        // 두상(패치 밖, 어깨 제외) 전파 오차 — 참고 지표 (실루엣 맞춤은 M3)
        let shoulders = Set(t.manifest.group(.shoulders))
        var errs: [Float] = []
        for i in 1220..<t.vertexCount where !shoulders.contains(i) { errs.append(simd_length(alignedAll[i] - user[i])) }
        errs.sort()
        let median = errs[errs.count / 2], p90 = errs[errs.count * 9 / 10]
        print("섭동 피팅: 두상 전파 오차 중앙값 \(median * 1000) mm · p90 \(p90 * 1000) mm · 최대 \(errs.last! * 1000) mm")
        #expect(median < 0.003, "중앙값 \(median)")
    }

    @Test("합성 번들 저장 → 읽기 왕복 (.coursonacapture)")
    func bundleRoundTrip() throws {
        let t = Self.template
        var opt = SyntheticCaptureOptions()
        opt.imageWidth = 160; opt.imageHeight = 120; opt.depthWidth = 160; opt.depthHeight = 120
        let bundle = SyntheticCapture.makeBundle(template: t, kinds: [.front, .left], options: opt)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).coursonacapture")
        defer { try? FileManager.default.removeItem(at: url) }
        try CaptureBundleStore.archive(bundle, to: url)
        let back = try CaptureBundleStore.readArchive(url)
        #expect(back.shots.count == 2)
        #expect(back.shots[0].meta.faceVertices == bundle.shots[0].meta.faceVertices)
        #expect(back.shots[0].depth == bundle.shots[0].depth)
        #expect(back.shots[0].image?.width == 160)
    }

    @Test("CPU 텍스처 투영: 관측 영역 PSNR 과 관측 비율")
    func textureProjection() throws {
        let t = Self.template
        var opt = SyntheticCaptureOptions()
        opt.imageWidth = 1280; opt.imageHeight = 960; opt.depthWidth = 640; opt.depthHeight = 480
        let bundle = SyntheticCapture.makeBundle(template: t, options: opt)
        var po = TextureProjectionOptions()
        po.size = 256
        // 합성 캡처는 렌더 메시(코너 UV)로 그려지므로 투영도 같은 메시로 (M4 에서 통일; 대칭 맵은 원본 정점 기준이라 끈다)
        let render = t.makeRenderMesh()
        let rPos = render.expand(t.positions)
        let mouthUV = render.uvs[render.sourceIndex.firstIndex(of: Int32(t.manifest.landmark(.lipUpperMid)!))!]
        let res = CPUTextureProjector.project(positions: rPos, normals: Geometry.vertexNormals(positions: rPos, indices: render.indices), uvs: render.uvs, indices: render.indices,
                                              shots: bundle.shots, symmetryMap: [], mouthUVCenter: mouthUV, options: po)
        let truth = SyntheticAlbedo.image(size: 256)
        let psnr = CPUTextureProjector.psnr(res.albedo, truth, mask: res.mask)
        print("텍스처: 관측 \(res.quality.observedRatio * 100)% · 대칭 \(res.quality.mirroredRatio * 100)% · 채움 \(res.quality.filledRatio * 100)% · PSNR \(psnr) dB · \(res.quality.buildSeconds) s")
        #expect(res.quality.observedRatio > 0.3)
        // M0 CPU 참조 구현 기준선 22 dB (1280×960 5컷, 256²). M4 `TextureBuilder` 는 대역 제한 알베도에서 32 dB 이상 (TextureBuilderTests).
        #expect(psnr > 22, "PSNR \(psnr)")
    }

    @Test("텍스처 진단: 컷 조합·탈조명별 PSNR (정보)")
    func textureDiagnostics() {
        let t = Self.template
        var opt = SyntheticCaptureOptions()
        opt.imageWidth = 480; opt.imageHeight = 360; opt.depthWidth = 480; opt.depthHeight = 360
        let bundle = SyntheticCapture.makeBundle(template: t, options: opt)
        let truth = SyntheticAlbedo.image(size: 256)
        let render = t.makeRenderMesh()
        let rPos = render.expand(t.positions), rNrm = Geometry.vertexNormals(positions: rPos, indices: render.indices)
        let mouthUV = render.uvs[render.sourceIndex.firstIndex(of: Int32(t.manifest.landmark(.lipUpperMid)!))!]
        func run(_ kinds: [ShotKind], delight: Float, mirror: Bool = false) -> String {
            var po = TextureProjectionOptions(); po.size = 256; po.delight = delight; po.mirrorFill = mirror
            let shots = bundle.shots.filter { kinds.contains($0.kind) }
            let r = CPUTextureProjector.project(positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices, shots: shots,
                                                symmetryMap: [], mouthUVCenter: mouthUV, options: po)
            return String(format: "%@ delight=%.1f → 관측 %.1f%% PSNR %.1f dB", kinds.map(\.rawValue).joined(separator: "+"), delight, r.quality.observedRatio * 100, CPUTextureProjector.psnr(r.albedo, truth, mask: r.mask))
        }
        print("480×360: " + run([.front], delight: 1))
        print("480×360: " + run([.front], delight: 0))
        print("480×360: " + run([.front, .left, .right, .up], delight: 1))
        var hi = SyntheticCaptureOptions()
        hi.imageWidth = 1280; hi.imageHeight = 960; hi.depthWidth = 640; hi.depthHeight = 480
        let hiBundle = SyntheticCapture.makeBundle(template: t, options: hi)
        var po = TextureProjectionOptions(); po.size = 256
        let r = CPUTextureProjector.project(positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices, shots: hiBundle.shots,
                                            symmetryMap: [], mouthUVCenter: mouthUV, options: po)
        print(String(format: "1280×960 5컷 → 관측 %.1f%% PSNR %.1f dB (%.2f s)", r.quality.observedRatio * 100, CPUTextureProjector.psnr(r.albedo, truth, mask: r.mask), r.quality.buildSeconds))
    }

    @Test("Identity · bust.mesh 바이너리 왕복")
    func binaryRoundTrips() throws {
        let t = Self.template
        var id = Identity.fromTemplate(t)
        id.patchDeltas[.jawOpen] = Array(t.shapeDeltas[.jawOpen]![0..<1220])
        id.quality = FitQuality(patchRMS: 0.001, patchRMSPerShot: ["front": 0.001], silhouetteResidualMedian: nil, rbfLambda: 0, rbfPivotRatio: 1, shotsUsed: 4, elapsedSeconds: 0.5)
        let data = try id.serialized()
        let back = try Identity(serialized: data)
        #expect(back == id)
        let meshData = BustMeshFile.write(t)
        let t2 = try BustMeshFile.read(meshData, manifest: t.manifest)
        #expect(t2.positions == t.positions)
        #expect(t2.indices == t.indices)
        #expect(t2.shapeDeltas[.jawOpen] == t.shapeDeltas[.jawOpen])
        #expect(t2.skeleton?.jointNames == t.skeleton?.jointNames)
        #expect(t2.skin[1300] == t.skin[1300])
    }
}
