import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaTexture
@testable import CoursonaIO

/// M3 피팅 (T-301 ~ T-308). 합성 템플릿·합성 번들로 수치 회귀를 지킨다. 실기기 픽스처 3세트(T-207)는 저장소 밖 — CLI `--fit` 로 잰다.
@Suite("M3 피팅", .serialized)
struct FitTests {
    static let template = SyntheticTemplate.make()

    /// 깊이 640×480 (실기기 480×640 과 비슷한 밀도 — 320×240 이면 법선 선 3 mm 안에 포인트가 2개뿐이라 대응이 거의 안 잡힌다).
    static func bundle(_ user: [SIMD3<Float>]? = nil, template t: BustTemplate = template, kinds: [ShotKind] = ShotKind.allCases) -> CaptureBundle {
        var opt = SyntheticCaptureOptions()
        opt.imageWidth = 640; opt.imageHeight = 480; opt.depthWidth = 640; opt.depthHeight = 480
        return SyntheticCapture.makeBundle(template: t, userPositions: user, kinds: kinds, options: opt)
    }

    /// 정답과 강체 정렬(패치 기준) 후 두상(패치 밖·어깨 제외) 오차 중앙값·p90 (m).
    static func headError(_ id: Identity, truth: [SIMD3<Float>], template t: BustTemplate) -> (median: Float, p90: Float, patch: Float) {
        let fitted = Array(id.positions[0..<1220]), truthPatch = Array(truth[0..<1220])
        let R = Procrustes.fit(source: fitted, target: truthPatch, allowScale: false)!
        let all = id.positions.map { R.apply($0) }
        let shoulders = Set(t.manifest.group(.shoulders))
        var errs: [Float] = []
        for i in 1220..<t.vertexCount where !shoulders.contains(i) { errs.append(simd_length(all[i] - truth[i])) }
        errs.sort()
        return (errs[errs.count / 2], errs[errs.count * 9 / 10], Geometry.rms(Array(all[0..<1220]), truthPatch))
    }

    // MARK: ARKit 이름

    @Test("ARKit BlendShapeLocation 표기(`mouthSmile_L`)도 52개 전부 매핑된다 — M2 캡처가 좌우 28개를 0 으로 저장하던 원인")
    func arkitNames() {
        for s in ArkitShape.allCases {
            #expect(ArkitShape(arkitName: s.arkitLocationName) == s, "\(s.arkitLocationName)")
            #expect(ArkitShape(arkitName: s.rawValue) == s)
        }
        // ARKit 표기에서 `_L`/`_R` 인 것은 36개 (jawLeft/Right · mouthLeft/Right 는 방향이라 그대로)
        #expect(ArkitShape.allCases.filter { $0.arkitLocationName.hasSuffix("_L") || $0.arkitLocationName.hasSuffix("_R") }.count == 36)
        #expect(ArkitShape.jawLeft.arkitLocationName == "jawLeft" && ArkitShape.mouthSmileLeft.arkitLocationName == "mouthSmile_L")
        let w = ArkitWeights(named: ["mouthSmile_L": 0.8, "eyeBlink_R": 0.5, "jawOpen": 0.2, "nope_L": 1])
        #expect(w[.mouthSmileLeft] == 0.8 && w[.eyeBlinkRight] == 0.5 && w[.jawOpen] == 0.2 && w.sum == 1.5)
    }

    // MARK: 수학

    @Test("구 피팅: 구면 점 → 중심·반지름 복원, 루프 법선·반지름")
    func sphereFit() {
        let c = SIMD3<Float>(0.03, 0.44, 0.06), r: Float = 0.012
        var rng = SplitMix64(seed: 3)
        let pts = (0..<30).map { _ -> SIMD3<Float> in
            let d = simd_normalize(SIMD3(Float(rng.gaussian()), Float(rng.gaussian()), Float(rng.gaussian())))
            return c + d * r
        }
        let s = SphereFit.algebraic(pts)!
        #expect(simd_length(s.center - c) < 1e-5 && abs(s.radius - r) < 1e-5)
        // 원(평면 고리): 법선 ±Z, 반지름 ρ
        let ring = (0..<24).map { i -> SIMD3<Float> in let a = Float(i) / 24 * 2 * .pi; return SIMD3(0.01 * cos(a), 0.01 * sin(a), 0.5) }
        let n = SphereFit.loopNormal(ring)!
        #expect(abs(abs(n.z) - 1) < 1e-5)
        #expect(abs(SphereFit.loopRadius(ring, normal: n) - 0.01) < 1e-5)
    }

    @Test("공액기울기: 작은 SPD 계를 밀집 풀이와 같은 답으로")
    func conjugateGradient() {
        // 1D 체인 라플라시안 + I (SPD), 성분별 독립
        let n = 40
        var A = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            A[i * n + i] = 3
            if i > 0 { A[i * n + i - 1] = -1 }
            if i + 1 < n { A[i * n + i + 1] = -1 }
        }
        let b = (0..<n).map { SIMD3<Float>(Float($0 % 7) - 3, sin(Float($0)), 1) }
        var B = [Double](repeating: 0, count: n * 3)
        for i in 0..<n { B[i * 3] = Double(b[i].x); B[i * 3 + 1] = Double(b[i].y); B[i * 3 + 2] = Double(b[i].z) }
        let dense = DenseSolver.solve(A, B, n: n, k: 3)!
        let diag = [SIMD3<Float>](repeating: SIMD3(repeating: 3), count: n)
        let cg = ConjugateGradient.solve(b: b, diagonal: diag, maxIterations: 200, tolerance: 1e-8) { x in
            (0..<n).map { i in
                var v = x[i] * 3
                if i > 0 { v -= x[i - 1] }
                if i + 1 < n { v -= x[i + 1] }
                return v
            }
        }
        var maxErr: Float = 0
        for i in 0..<n { maxErr = max(maxErr, simd_length(cg.x[i] - SIMD3(Float(dense.x[i * 3]), Float(dense.x[i * 3 + 1]), Float(dense.x[i * 3 + 2])))) }
        #expect(maxErr < 1e-4, "최대 오차 \(maxErr), 반복 \(cg.iterations)")
        #expect(cg.iterations < 60)
    }

    // MARK: T-301 · T-302

    @Test("패치 솔버: 정렬·중립화·평균 → 템플릿 자체는 0.1 mm 이내, 눈알은 링 피팅 또는 사전값으로 manifest 근처")
    func patchSolver() throws {
        let t = Self.template
        let sol = try FacePatchSolver.solve(bundle: Self.bundle(), template: t)
        #expect(sol.shotsUsed == 4)
        #expect(sol.alignments.count == 5, "미소 컷도 정렬된다")
        #expect(Geometry.rms(sol.userPatch, Array(t.patchPositions)) < 0.0001)
        #expect(abs(sol.scale - 1) < 0.002)
        // 눈: 합성 템플릿의 눈꺼풀 고리는 타원체 위라 구가 안 맞아 사전값(prior)으로 간다 — 어느 쪽이든 manifest 눈 중심에서 6 mm 이내, 반지름 9–16 mm
        #expect(sol.eyeFit.contains("ring") || sol.eyeFit.contains("prior"), "\(sol.eyeFit)")
        #expect(simd_length(sol.eyeCenterL - t.manifest.eyeCenterL) < 0.006, "L \(sol.eyeCenterL) vs \(t.manifest.eyeCenterL)")
        #expect(simd_length(sol.eyeCenterR - t.manifest.eyeCenterR) < 0.006)
        #expect(sol.eyeRadius > 0.009 && sol.eyeRadius < 0.016)
        print("눈알: \(sol.eyeFit) · L \(sol.eyeCenterL * 1000) · R \(sol.eyeCenterR * 1000) · r \(sol.eyeRadius * 1000) mm")
    }

    @Test("눈꺼풀 링이 진짜 구면 위에 있으면 ring 피팅이 채택된다")
    func eyeRingOnSphere() {
        let t = Self.template
        var patch = Array(t.patchPositions)
        // 왼눈 고리를 반지름 12 mm 구면(중심 = manifest 눈 중심) 위로 투영
        let c = t.manifest.eyeCenterL
        for id in t.manifest.patchLoops["eye_left"]! {
            let d = simd_normalize(patch[id] - c)
            patch[id] = c + d * 0.012
        }
        let e = FacePatchSolver.estimateEyes(userPatch: patch, template: t, scale: 1)
        #expect(e.fit.hasPrefix("ring"), "\(e.fit)")
        #expect(simd_length(e.left - c) < 0.003, "\(e.left) vs \(c)")
    }

    // MARK: T-304

    @Test("실루엣 맞춤: 템플릿 자체는 당기지 않고(≤ 0.3 mm), 섭동 사용자는 두상 오차가 줄고 잔차 중앙값 < 3 mm")
    func silhouette() throws {
        let t = Self.template
        // (a) 템플릿 그대로 → 셀프 피팅 RMS < 0.2 mm 유지, 실루엣 잔차 ≈ 0
        let idSelf = try FaceFitter.fit(bundle: Self.bundle(), template: t)
        let selfRMS = Geometry.rms(idSelf.positions, t.positions)
        let qs = idSelf.quality!
        print(String(format: "셀프+실루엣: 전체 RMS %.3f mm · 잔차 중앙값 %.3f mm · 대응 %d/%d · 포인트 %d", selfRMS * 1000, (qs.silhouetteResidualMedian ?? 0) * 1000, qs.silhouetteVertices ?? 0, 0, qs.silhouettePoints ?? 0))
        #expect(selfRMS < 0.0002)
        #expect((qs.silhouetteResidualMedian ?? 1) < 0.0003)
        #expect((qs.silhouetteVertices ?? 0) > 500)

        // (b) 섭동 사용자: 실루엣 끔 vs 켬 (합성 "머리카락" 은 텍스처일 뿐 깊이는 진짜 두상이므로 두피 제외도 끈 변형을 함께 본다)
        let user = SyntheticTemplate.perturbed(t, .sample)
        let b = Self.bundle(user)
        var off = FitOptions(); off.silhouette.enabled = false
        let idOff = try FaceFitter.fit(bundle: b, template: t, options: off)
        let idOn = try FaceFitter.fit(bundle: b, template: t)
        var noHair = FitOptions(); noHair.silhouette.excludeHairOnScalp = false
        let idOnAll = try FaceFitter.fit(bundle: b, template: t, options: noHair)
        let eOff = Self.headError(idOff, truth: user, template: t)
        let eOn = Self.headError(idOn, truth: user, template: t)
        let eAll = Self.headError(idOnAll, truth: user, template: t)
        let qOn = idOn.quality!, qAll = idOnAll.quality!
        print(String(format: "섭동 두상 오차 중앙값/p90: 실루엣 끔 %.2f/%.2f mm → 켬(두피 머리카락 제외) %.2f/%.2f mm (잔차 %.2f mm, 대응 %d) → 두피 포함 %.2f/%.2f mm (잔차 %.2f mm, 대응 %d)",
                     eOff.median * 1000, eOff.p90 * 1000, eOn.median * 1000, eOn.p90 * 1000, (qOn.silhouetteResidualMedian ?? 0) * 1000, qOn.silhouetteVertices ?? 0,
                     eAll.median * 1000, eAll.p90 * 1000, (qAll.silhouetteResidualMedian ?? 0) * 1000, qAll.silhouetteVertices ?? 0))
        #expect(eOn.patch < 0.0002 && eAll.patch < 0.0002, "패치는 그대로")
        #expect((qOn.silhouetteResidualMedian ?? 1) < 0.003)
        #expect((qAll.silhouetteResidualMedian ?? 1) < 0.003)
        #expect(eOn.median <= eOff.median + 0.0002)
        #expect(eAll.median < eOff.median, "두피까지 당기면 두상 오차가 줄어야 한다")
        #expect(eAll.p90 < eOff.p90)
    }

    // MARK: T-305

    @Test("jawOpen 진폭 보정: 턱 델타가 1.3배인 사용자 → ×1.3 복원, 미소 잔차 감소, identity.bin v2 왕복")
    func jawOpenCalibration() throws {
        let t = Self.template
        var userT = t
        userT.shapeDeltas[.jawOpen] = t.shapeDeltas[.jawOpen]!.map { $0 * 1.3 }
        let b = Self.bundle(nil, template: userT)
        let id = try FaceFitter.fit(bundle: b, template: t)
        let q = id.quality!
        print(String(format: "jawOpen ×%.3f · 미소 잔차 %.3f mm · 셰이프 스케일 %@", q.jawOpenScale ?? -1, (q.smileResidualRMS ?? 0) * 1000, "\(id.shapeScales)"))
        #expect(abs((q.jawOpenScale ?? 0) - 1.3) < 0.08)
        #expect(id.shapeScales[.jawOpen] != nil && id.patchDeltas[.jawOpen]?.count == 1220)
        #expect((q.smileResidualRMS ?? 1) < 0.0005)
        // 보정 없이 풀면 미소 잔차가 더 크다
        var noCal = FitOptions(); noCal.calibrateJawOpen = false
        let idNo = try FaceFitter.fit(bundle: b, template: t, options: noCal)
        #expect((idNo.quality!.smileResidualRMS ?? 0) > (q.smileResidualRMS ?? 0))
        // runtimeDeltas: 패치는 보정 델타, 밖은 scale × 1.3
        let rd = id.runtimeDeltas(template: t)[.jawOpen]!
        let tj = t.shapeDeltas[.jawOpen]!
        let outside = (1220..<t.vertexCount).first { simd_length(tj[$0]) > 1e-4 }!
        #expect(abs(simd_length(rd[outside]) / simd_length(tj[outside]) - id.scale * (q.jawOpenScale ?? 1)) < 0.01)
        // 직렬화 v2
        let back = try Identity(serialized: id.serialized())
        #expect(back == id)
        #expect(back.shapeScales[.jawOpen] == id.shapeScales[.jawOpen])
        #expect(back.quality?.method == "dense" && back.quality?.jawOpenScale == q.jawOpenScale)
    }

    // MARK: T-306

    /// 합성 "사용자" 를 가상 카메라 여러 대(기본: 정면 한 대)로 찍은 희소 번들 (키포인트 8점·컷마다, 깊이·1220 정점 없음).
    /// `SyntheticCapture.makeSparseBundle` 를 640×480 으로 감싼 것 — CLI `--make-fixture <file> sparse` 도 같은 함수를 쓴다.
    static func sparseBundle(user: [SIMD3<Float>], template t: BustTemplate, kinds: [ShotKind] = [.front]) -> CaptureBundle {
        var opt = SyntheticCaptureOptions()
        opt.imageWidth = 640; opt.imageHeight = 480
        return SyntheticCapture.makeSparseBundle(template: t, userPositions: user, kinds: kinds, options: opt)
    }

    @Test("희소 폴백: 사진 1장(랜드마크 8점) → 턱 길이·입 폭이 사진 쪽으로, 스케일은 1 고정, 눈알·정점 수 유지")
    func sparseFit() throws {
        let t = Self.template
        // 턱만 8 mm 늘린 사용자 (눈꼬리는 그대로 → 눈 간격 정규화가 1 이라 절대 치수로 비교할 수 있다)
        let user = SyntheticTemplate.perturbed(t, SyntheticTemplate.Perturbation(scale: 1, noseBump: 0, chinExtend: 0.008, cheekWidth: 0))
        let b = Self.sparseBundle(user: user, template: t)
        #expect(b.shots[0].meta.isSparse)
        let id = try FaceFitter.fit(bundle: b, template: t)   // 거부하지 않고 SparseFitter 로 간다
        let q = try #require(id.quality)
        #expect(q.method == "sparse" && q.landmarksUsed == 8 && id.scale == 1)
        #expect(id.positions.count == t.vertexCount)
        // 단안 사진의 형상은 **눈 간격 대비 비율**로만 재현된다(템플릿을 "눈 간격이 사진과 같아지는 깊이" 에 둔다). 눈꼬리를 안 건드린 섭동이라 절대 치수와 같다.
        let chin = t.manifest.landmark(.chin)!
        let dChin = id.positions[chin].y - t.positions[chin].y
        let truthChin = user[chin].y - t.positions[chin].y
        print(String(format: "희소: 턱 이동 %.2f mm (정답 %.2f) · λ %.3g · 피벗비 %.3g · 메모 %@", dChin * 1000, truthChin * 1000, q.rbfLambda, q.rbfPivotRatio, q.notes ?? ""))
        #expect(abs(dChin - truthChin) < 0.001, "턱 \(dChin) vs \(truthChin)")
        // 입꼬리(ph −32.5°)는 턱 연장(ph < −35°) 밖 → 거의 안 움직인다
        let ml = t.manifest.landmark(.mouthLeft)!
        #expect(simd_length(id.positions[ml] - t.positions[ml]) < 0.0015)
        // 두상 뒤쪽(랜드마크에서 멀다)은 거의 안 움직인다
        let back = (1220..<t.vertexCount).first { t.positions[$0].z < -0.08 && t.positions[$0].y > 0.4 }!
        #expect(simd_length(id.positions[back] - t.positions[back]) < 0.001)
        // 눈알은 템플릿 근처, 직렬화 왕복
        #expect(simd_length(id.eyeCenterL - t.manifest.eyeCenterL) < 0.004)
        let back2 = try Identity(serialized: id.serialized())
        #expect(back2.quality?.method == "sparse" && back2.quality?.landmarksUsed == 8)
        // 랜드마크가 부족하면 명확한 오류
        var poor = b
        poor.shots[0].meta.keyPoints2D = ["nose_tip": [320, 240]]
        poor.meta.shots = [poor.shots[0].meta]
        #expect(throws: FitError.self) { try FaceFitter.fit(bundle: poor, template: t) }
    }

    /// 코가 카메라 쪽으로(+Z) 튀어나온 건 **정면 한 장으로는 거의 안 보인다**(시선 축 변위) — 좌·우·위 컷을 더하면
    /// 광선 삼각측량으로 그 깊이가 드러나야 한다(SparseFitter.swift 머리말의 "측면 컷으로 코 높이 보강").
    @Test("희소 폴백 다시점: 코 깊이(+Z)는 정면 한 장보다 5컷 삼각측량이 정답에 더 가깝다")
    func sparseFitMultiShot() throws {
        let t = Self.template
        let user = SyntheticTemplate.perturbed(t, SyntheticTemplate.Perturbation(scale: 1, noseBump: 0.01, chinExtend: 0, cheekWidth: 0))
        let nose = t.manifest.landmark(.noseTip)!
        let truthZ = user[nose].z - t.positions[nose].z

        let single = Self.sparseBundle(user: user, template: t, kinds: [.front])
        let idSingle = try FaceFitter.fit(bundle: single, template: t)
        let zSingle = idSingle.positions[nose].z - t.positions[nose].z

        let kinds: [ShotKind] = [.front, .left, .right, .up]
        let multi = Self.sparseBundle(user: user, template: t, kinds: kinds)
        let idMulti = try FaceFitter.fit(bundle: multi, template: t)
        let qMulti = try #require(idMulti.quality)
        #expect(qMulti.method == "sparse" && qMulti.shotsUsed == kinds.count)
        let zMulti = idMulti.positions[nose].z - t.positions[nose].z

        print(String(format: "코 깊이: 정답 %.2f mm · 단일 컷 %.2f mm(오차 %.2f) · 다시점 %.2f mm(오차 %.2f)",
                     truthZ * 1000, zSingle * 1000, abs(zSingle - truthZ) * 1000, zMulti * 1000, abs(zMulti - truthZ) * 1000))
        #expect(abs(zMulti - truthZ) < abs(zSingle - truthZ), "다시점 삼각측량이 단일 컷보다 코 깊이를 더 잘 복원해야 한다")

        // FaceFitter.alignments 는 쓰인 모든 중립 컷에 정렬을 돌려준다 — M4 TextureBuilder 가 쓸 수 있어야 한다(T-306 다시점).
        let aligns = FaceFitter.alignments(bundle: multi, template: t)
        #expect(Set(aligns.keys) == Set(kinds))
    }

    // MARK: T-308

    @Test("미소 검증 렌더: 미소 컷 카메라로 그린 흉상과 사진이 같은 크기, 미소 잔차 < 0.3 mm")
    func smileVerification() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = try FaceFitter.fit(bundle: b, template: t)
        let aligns = FaceFitter.alignments(bundle: b, template: t)
        let v = try #require(SmileVerification.make(bundle: b, template: t, identity: id, alignments: aligns, albedo: SyntheticAlbedo.image(size: 256), width: 160))
        #expect(v.kind == .smile && v.photo.width == 160 && v.render.width == 160 && v.photo.height == v.render.height && v.sideBySide.width == 324)
        #expect(v.weightSum > 1)
        // 렌더에 흉상이 실제로 찍혔다 (가운데 픽셀이 배경색이 아니다)
        let c = v.render[80, v.render.height / 2]
        #expect(c.x > 60, "가운데 픽셀 \(c)")
        #expect((id.quality?.smileResidualRMS ?? 1) < 0.0003)
        // 사진과 렌더의 실루엣이 비슷하다: 각 행에서 배경이 아닌 픽셀 수의 차이 (렌더 배경 (20,22,26) vs 합성 사진 배경 동일)
        var diffRows = 0
        for y in Swift.stride(from: 0, to: v.render.height, by: 8) {
            func cover(_ img: RGBAImage) -> Int { (0..<img.width).filter { x in let p = img[x, y]; return !(p.x == 20 && p.y == 22 && p.z == 26) }.count }
            if abs(cover(v.photo) - cover(v.render)) > 12 { diffRows += 1 }
        }
        #expect(diffRows <= 3, "실루엣이 다른 행 \(diffRows)")
    }
}
