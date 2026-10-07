//
//  coursona-validate — 블렌더 산출물 계약 검사 CLI (macOS)
//
//  사용법:
//    swift run coursona-validate <Template 폴더> [--with-usdz]   template.json + bust.mesh + library + clips + previz 검사 (+ Template.usdz 를 RealityKit 으로 읽어 교차 확인)
//    swift run coursona-validate --synthetic <출력 폴더>     합성 템플릿으로 Template/ 폴더를 만들고 검사(자체 테스트)
//    swift run coursona-validate --list-legacy-failures      소반 임시 USDZ 로는 어떤 검사가 실패하는지 목록(M1 T-105 우선순위)
//    swift run coursona-validate --make-fixture <파일.coursonacapture> [perturbed|sparse|sparse-perturbed]   합성 캡처 번들 픽스처 생성 (Fixtures/)
//      sparse* 는 깊이·ARKit 메시 없는 희소(사진 폴백, 맥·TrueDepth 없는 기기) 4컷(정면·좌·우·위) — T-306 다시점 경로 점검용
//    swift run coursona-validate --texture <번들.coursonacapture> <출력.png> [크기] [템플릿.coursonatemplate]   피팅 + 알베도 투영 → PNG (텍스처 디버깅)
//    swift run coursona-validate --fit <번들.coursonacapture> [출력.png] [템플릿.coursonatemplate]   M3 피팅 품질 전체 출력 + 미소 검증(사진 | 렌더) PNG
//  종료 코드: 0 = 오류 없음, 1 = 오류 있음, 2 = 입력 오류.
//  USDZ 자체(RealityKit 로드)는 앱의 "검증" 탭에서 같은 규칙으로 검사한다(CoursonaRig.TemplateLoader).
//

import Foundation
import CoursonaCore
import CoursonaIO
import CoursonaValidate
import CoursonaTexture
import CoursonaFit
import CoursonaFace
import CoursonaCapture
#if os(macOS)
import CoursonaRig
import RealityKit
#endif

let args = CommandLine.arguments.dropFirst().filter { $0 != "--with-usdz" } + CommandLine.arguments.dropFirst().filter { $0 == "--with-usdz" }

#if os(macOS)
final class USDZBox: @unchecked Sendable { var done = false; var positions: [SIMD3<Float>]?; var shapes: [String]?; var summary = "" }
#endif

/// CLI 는 앱 번들이 없으므로 저장소의 `Default.coursonatemplate` 를 임시 폴더에 풀어 읽는다 (경로를 주면 그 파일).
/// 반환: 템플릿 + 지워야 할 임시 폴더.
func loadRepoTemplate(override: String?) throws -> (BustTemplate, URL) {
    let zip = override.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Coursona/Resources/Templates/Default.coursonatemplate")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tpl-\(UUID().uuidString)")
    try ZipArchive.unzip(Data(contentsOf: zip), to: dir)
    return (try TemplateStore.loadTemplate(from: dir), dir)
}

func run() -> Int32 {
    guard let first = args.first else {
        print("사용법: coursona-validate <Template 폴더> | --synthetic <폴더> | --list-legacy-failures")
        return 2
    }
    if first == "--list-legacy-failures" {
        // 소반 USDZ(DemoAvatar_Ethan / SplatPlaceholder_Bust)는 계약 메타가 없으므로 template.json 없이 돌리면 어떤 검사가 실패하는지 보여준다.
        var m = TemplateManifest(id: "soban-legacy", version: "0", vertexCount: 0, triangleCount: 0, patchTriangleHash: "0", landmarks: [:], groups: [:], shapeKeys: [])
        m.libraryObjects = []
        let issues = TemplateValidator.validate(ValidationInput(manifest: m, template: nil, clips: [], previzNames: [], library: [], hasUSDZ: true, hasBustMesh: false))
        print(TemplateValidator.report(issues, title: "소반 임시 USDZ (계약 메타 없음)"))
        print("\n→ 블렌더 작업 우선순위: ① ARFaceGeometry.obj 패치 + 그룹 ② 52 셰이프키 ③ 스켈레톤·랜드마크(template.json) ④ 클립 ⑤ 라이브러리 ⑥ previz")
        return 1
    }
    if first == "--make-fixture" {
        guard args.count >= 2 else { print("--make-fixture <출력.coursonacapture> [perturbed]"); return 2 }
        let url = URL(fileURLWithPath: args[args.startIndex + 1])
        let mode = args.count >= 3 ? args[args.startIndex + 2] : ""
        let perturbed = mode == "perturbed" || mode == "sparse-perturbed"
        let sparse = mode == "sparse" || mode == "sparse-perturbed"
        let t = SyntheticTemplate.make()
        let user = perturbed ? SyntheticTemplate.perturbed(t, .sample) : nil
        let bundle: CaptureBundle
        let desc: String
        if sparse {
            var opt = SyntheticCaptureOptions()
            opt.imageWidth = 1280; opt.imageHeight = 960
            bundle = SyntheticCapture.makeSparseBundle(template: t, userPositions: user, options: opt)
            desc = "희소\(perturbed ? "(섭동 사용자)" : "(템플릿 그대로)") · 4컷(정면·좌·우·위) 1280×960 · 깊이·ARKit 메시 없음"
        } else {
            var opt = SyntheticCaptureOptions()
            opt.imageWidth = 1280; opt.imageHeight = 960; opt.depthWidth = 640; opt.depthHeight = 480
            bundle = SyntheticCapture.makeBundle(template: t, userPositions: user, options: opt)
            desc = "\(perturbed ? "(섭동 사용자)" : "(템플릿 그대로)") · 5컷 1280×960 + 깊이 640×480"
        }
        do { try CaptureBundleStore.archive(bundle, to: url) } catch { print("쓰기 실패: \(error)"); return 2 }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("합성 번들 \(desc) → \(url.path) (\(size / 1024) KB)")
        return 0
    }
    if first == "--texture" {
        // 실제 캡처 번들로 피팅 + M4 텍스처 빌더(2k 기본, Metal) 를 돌려 PNG 로 뽑는다 (텍스처 디버깅·빌드 시간 측정).
        // 캡처 데이터는 커밋하지 않는다 — 출력도 저장소 밖에 쓴다. `--texture <번들> <out.png> [크기] [템플릿] [delight=0.5] [cpu=1] [legacy=1]`
        guard args.count >= 3 else { print("--texture <번들.coursonacapture> <출력.png> [크기] [템플릿.coursonatemplate] [delight=0.5] [cpu=1] [legacy=1]"); return 2 }
        let src = URL(fileURLWithPath: args[args.startIndex + 1])
        let out = URL(fileURLWithPath: args[args.startIndex + 2])
        let size = args.count >= 4 ? Int(args[args.startIndex + 3]) ?? 2048 : 2048
        let flags = Dictionary(uniqueKeysWithValues: args.dropFirst(4).compactMap { a -> (String, String)? in
            let p = a.split(separator: "=", maxSplits: 1).map(String.init); return p.count == 2 ? (p[0], p[1]) : nil })
        do {
            let bundle = try CaptureBundleStore.readArchive(src)
            let tplArg = args.count >= 5 && !args[args.startIndex + 4].contains("=") ? args[args.startIndex + 4] : nil
            let (template, dir) = try loadRepoTemplate(override: tplArg)
            defer { try? FileManager.default.removeItem(at: dir) }
            print("번들: \(bundle.meta.device) · 컷 \(bundle.shots.count) · sparse \(bundle.meta.sparse)")
            let identity = try FaceFitter.fit(bundle: bundle, template: template)
            let q = identity.quality
            print(String(format: "피팅: 패치 RMS %.2f mm · 스케일 %.3f · %.1f s", (q?.patchRMS ?? 0) * 1000, identity.scale, q?.elapsedSeconds ?? 0))
            let aligns = FaceFitter.alignments(bundle: bundle, template: template)
            let albedoOut: RGBAImage, maskOut: RGBAImage
            if flags["legacy"] == "1" {
                let r = try CaptureTexturing.project(bundle: bundle, template: template, positions: identity.positions,
                                                     alignments: aligns, options: CaptureTexturing.deviceOptions(size: size))
                print(String(format: "텍스처(M4 1차 CPU 투영기): 관측 %.1f%% · 대칭 %.1f%% · 채움 %.1f%% · %.1f s · 컷 %@",
                             r.quality.observedRatio * 100, r.quality.mirroredRatio * 100, r.quality.filledRatio * 100,
                             r.quality.buildSeconds, r.usedShots.map(\.rawValue).joined(separator: "+")))
                albedoOut = r.albedo; maskOut = r.mask
            } else {
                var o = TextureBuildOptions.preset(size: size)
                if let d = flags["delight"].flatMap(Float.init) { o.delight = d }
                if flags["cpu"] == "1" { o.preferMetal = false }
                if let p = flags["probe"] {
                    let c = p.split(separator: ",").compactMap { Float($0) }
                    if c.count == 2 {
                        print("텍셀 진단:")
                        for line in try TextureBuilder.probe(bundle: bundle, template: template, identity: identity, alignments: aligns, uv: SIMD2(c[0], c[1]), options: o) { print(line) }
                    }
                }
                let r = try TextureBuilder.build(bundle: bundle, template: template, identity: identity, alignments: aligns, options: o) { stage, f in
                    if f >= 1 { print(String(format: "  단계 %d %@ 완료", stage.rawValue + 1, stage.title)) }
                }
                print("텍스처(M4 TextureBuilder): " + r.summary)
                print("  단계별 초: " + zip(TextureStage.allCases, r.stageSeconds).map { String(format: "%@ %.2f", $0.title, $1) }.joined(separator: " · "))
                print("  조명: " + r.lights.sorted { $0.key.rawValue < $1.key.rawValue }.map { k, l in
                    String(format: "%@ %@ ℓ(%.2f, %.2f, %.2f) f %.2f", k.rawValue, l.source, l.towardLight.x, l.towardLight.y, l.towardLight.z, l.ambientFraction) }.joined(separator: " · "))
                print("  깊이 오프셋: " + r.depthOffsets.sorted { $0.key.rawValue < $1.key.rawValue }.map { String(format: "%@ %+.1f mm", $0.key.rawValue, $0.value * 1000) }.joined(separator: " · "))
                if let h = r.hairColor { print(String(format: "  머리카락색 (%.0f, %.0f, %.0f)", h.x * 255, h.y * 255, h.z * 255)) }
                if let s = r.skinColor { print(String(format: "  피부 기준색 (%.0f, %.0f, %.0f) · 얼굴 밖 관측 중 버린 텍셀 %d", s.x * 255, s.y * 255, s.z * 255, r.rejectedTexels)) }
                albedoOut = r.albedo; maskOut = r.mask
            }
            let r = (albedo: albedoOut, mask: maskOut)
            // 랜드마크 UV → 래스터라이저 텍셀 좌표 (어느 쪽이 얼굴인지 확정용)
            let render = template.makeRenderMesh()
            for name in [LandmarkName.noseTip, .chin, .eyeLeftOuter, .mouthLeft] {
                guard let src = template.manifest.landmark(name), let i = render.sourceIndex.firstIndex(of: Int32(src)) else { continue }
                let uv = render.uvs[i]
                print(String(format: "  %@: uv(%.3f, %.3f) → 래스터 텍셀 y=%.0f/%d (%@)",
                             name.rawValue, uv.x, uv.y, (1 - uv.y) * Float(size), size,
                             (1 - uv.y) < 0.5 ? "이미지 위쪽" : "이미지 아래쪽"))
            }
            // 부위별 UV 세로 범위 (반전하면 어디로 가는지 판단용)
            func vRange(_ ids: [Int]) -> (Float, Float)? {
                var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                let set = Set(ids.map(Int32.init))
                for i in 0..<render.vertexCount where set.contains(render.sourceIndex[i]) {
                    lo = min(lo, render.uvs[i].y); hi = max(hi, render.uvs[i].y)
                }
                return lo <= hi ? (lo, hi) : nil
            }
            print("부위별 UV v 범위 (0 = 래스터 이미지 아래, 1 = 위):")
            if let f = vRange(Array(0..<template.patchCount)) { print(String(format: "  얼굴 패치(1220):  v %.3f…%.3f", f.0, f.1)) }
            for g in [VertexGroupName.scalp, .neck, .shoulders] {
                if let r2 = vRange(template.manifest.group(g)) { print(String(format: "  %-14@ v %.3f…%.3f", g.rawValue as NSString, r2.0, r2.1)) }
            }
            try ImageCodec.png(r.albedo).write(to: out)
            try? ImageCodec.png(r.mask).write(to: out.deletingPathExtension().appendingPathExtension("mask.png"))
            print("→ \(out.path)")
            return 0
        } catch {
            print("실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            return 2
        }
    }
    if first == "--fit" {
        // M3 피팅 품질 전체 (T-307 수치 기록용) + 미소 검증 PNG (T-308). 캡처 데이터·출력은 저장소 밖에.
        guard args.count >= 2 else { print("--fit <번들.coursonacapture> [출력.png] [템플릿.coursonatemplate]"); return 2 }
        let src = URL(fileURLWithPath: args[args.startIndex + 1])
        let out = args.count >= 3 ? URL(fileURLWithPath: args[args.startIndex + 2]) : nil
        do {
            let bundle = try CaptureBundleStore.readArchive(src)
            let (template, dir) = try loadRepoTemplate(override: args.count >= 4 ? args[args.startIndex + 3] : nil)
            defer { try? FileManager.default.removeItem(at: dir) }
            print("번들: \(bundle.meta.device) · 컷 \(bundle.shots.map(\.kind.rawValue).joined(separator: "+")) · sparse \(bundle.meta.sparse) · 깊이 \(bundle.shots.filter { $0.depth != nil }.count)컷")
            // T-301: 필수 5컷 전부 깊이가 있는지(저장 전 검증과 같은 기준).
            let depthCov = DepthCoverage.check(bundle)
            print("  깊이 검증(T-301): " + (depthCov.isComplete ? "통과(필수 컷 전부 깊이 있음)" : "⚠︎ " + (depthCov.message ?? "")))
            print("템플릿: \(template.manifest.id)@\(template.manifest.version) · 정점 \(template.vertexCount)")
            let identity = try FaceFitter.fit(bundle: bundle, template: template)
            guard let q = identity.quality else { print("품질 지표 없음"); return 1 }
            print("피팅: " + q.summaryLine)
            print(String(format: "  스케일 %.3f · 눈 반지름 %.1f mm · 눈 L (%.1f, %.1f, %.1f) R (%.1f, %.1f, %.1f) mm", identity.scale, identity.eyeRadius * 1000,
                         identity.eyeCenterL.x * 1000, identity.eyeCenterL.y * 1000, identity.eyeCenterL.z * 1000,
                         identity.eyeCenterR.x * 1000, identity.eyeCenterR.y * 1000, identity.eyeCenterR.z * 1000))
            if !q.patchRMSPerShot.isEmpty {
                print("  컷별 패치 RMS: " + q.patchRMSPerShot.sorted { $0.key < $1.key }.map { String(format: "%@ %.2f mm", $0.key, $0.value * 1000) }.joined(separator: " · "))
            }
            if let m = q.silhouetteResidualMedian {
                print(String(format: "  실루엣: 잔차 중앙값 %.2f mm · p90 %.2f mm · 대응 정점 %d · 포인트 %d", m * 1000, (q.silhouetteResidualP90 ?? 0) * 1000, q.silhouetteVertices ?? 0, q.silhouettePoints ?? 0))
                if let off = q.depthOffsetPerShot { print("  깊이 → 메시 오프셋: " + off.sorted { $0.key < $1.key }.map { String(format: "%@ %+.1f mm", $0.key, $0.value * 1000) }.joined(separator: " · ")) }
            } else { print("  실루엣: 없음(깊이 컷 없음)") }
            if let j = q.jawOpenScale { print(String(format: "  jawOpen 진폭 ×%.3f", j)) } else { print("  jawOpen 진폭: 보정 안 함(미소 컷 jawOpen < 0.08)") }
            if let r = q.smileResidualRMS { print(String(format: "  미소 컷 잔차(변형 패치 vs ARKit): %.2f mm · 표정 없이 %.2f mm%@", r * 1000, (q.smileNeutralRMS ?? 0) * 1000,
                                                       r > (q.smileNeutralRMS ?? r) ? "  ⚠︎ 델타를 넣으니 더 멀어짐 — 템플릿 셰이프키가 ARKit 과 다르다" : "")) }
            if let n = q.notes { print("  메모: " + n) }
            print(String(format: "  RBF λ %.3g · 피벗비 %.3g", q.rbfLambda, q.rbfPivotRatio))
            // F6·F9(C2, T-209): 피팅 좌표로 눈·입 구멍을 닫고 자기교차(겹침) 지표를 낸다.
            var fittedForCaps = template
            if identity.positions.count == template.vertexCount { fittedForCaps.positions = identity.positions }
            let capped = CapBuilder.addingCaps(to: fittedForCaps)
            let capNames: [(String, CapClosure?)] = [("왼눈", capped.eyeLeft), ("오른눈", capped.eyeRight), ("입", capped.mouth)]
            print("  캡: " + capNames.map { name, c in c.map { "\(name) 테두리 \($0.ringSize)점" } ?? "\(name) 못 찾음" }.joined(separator: " · "))
            let selfX = SelfIntersectionCheck.check(capped)
            if selfX.isEmpty { print("  자기교차: 0건(겹침 없음)") }
            else { print("  자기교차: " + selfX.map { "\($0.shape.rawValue) \($0.flippedTriangles)개" }.joined(separator: " · ")) }
            // 눈 감기 점검(D-401 후속, 2026-10-08): 진짜 눈알(반지름 identity.eyeRadius, 중심 identity.eyeCenter)이 붙었을 때
            // eyeBlink 1.0 에서 눈꺼풀(눈 중심 1.9r 안의 **패치** 정점 — LidInner 안쪽 띠는 설계상 구면 안이라 제외)이 구면 안으로
            // 들어가면 눈을 감아도 눈알이 눈꺼풀을 뚫고 보인다. 양수 = 눈꺼풀이 눈알 바깥.
            for (name, c, shape) in [("왼눈", identity.eyeCenterL, ArkitShape.eyeBlinkLeft), ("오른눈", identity.eyeCenterR, .eyeBlinkRight)] {
                let r = identity.eyeRadius
                let delta = identity.patchDeltas[shape] ?? template.shapeDeltas[shape] ?? []
                var minOpen = Float.greatestFiniteMagnitude, minClosed = Float.greatestFiniteMagnitude, n = 0
                var frontOpen: Float = -1, frontClosed: Float = -1   // 눈 중심 바로 앞(+Z) 쪽 눈꺼풀의 구면 거리
                for v in 0..<min(template.patchCount, identity.positions.count) {
                    let p = identity.positions[v]
                    let dOpen = simd_length(p - c)
                    guard dOpen < r * 1.9 else { continue }
                    n += 1
                    minOpen = min(minOpen, dOpen - r)
                    let q = v < delta.count ? p + delta[v] : p
                    minClosed = min(minClosed, simd_length(q - c) - r)
                    let lateral = simd_length(SIMD2(q.x - c.x, q.y - c.y))
                    if lateral < r * 0.35 && q.z > c.z { frontClosed = max(frontClosed, simd_length(q - c) - r) }
                    if simd_length(SIMD2(p.x - c.x, p.y - c.y)) < r * 0.35 && p.z > c.z { frontOpen = max(frontOpen, dOpen - r) }
                }
                // 눈 구멍 테두리(캡이 닫은 고리 = 실제로 보이는 눈꺼풀 가장자리)가 눈을 감을 때 얼마나 닫히나: 고리의 세로 폭(뜸 → 감음).
                if let closure = (shape == .eyeBlinkLeft ? capped.eyeLeft : capped.eyeRight) {
                    let ids = closure.loopVertexIDs.filter { $0 < capped.template.positions.count }
                    let dAll = capped.template.shapeDeltas[shape] ?? []
                    func extent(_ closed: Bool) -> (Float, Float) {
                        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                        for v in ids {
                            var p = capped.template.positions[v]
                            if closed, v < dAll.count { p += dAll[v] }
                            lo = min(lo, p.y); hi = max(hi, p.y)
                        }
                        return (lo, hi)
                    }
                    let (lo0, hi0) = extent(false), (lo1, hi1) = extent(true)
                    let ringDelta = ids.compactMap { $0 < dAll.count ? simd_length(dAll[$0]) : nil }
                    print(String(format: "    눈 구멍 테두리 %d점: 세로 폭 뜸 %.1f mm → 감음 %.1f mm (중심 y 기준 뜸 %+.1f…%+.1f, 감음 %+.1f…%+.1f) · 테두리 깜빡임 델타 평균 %.1f / 최대 %.1f mm",
                                 ids.count, (hi0 - lo0) * 1000, (hi1 - lo1) * 1000, (lo0 - c.y) * 1000, (hi0 - c.y) * 1000, (lo1 - c.y) * 1000, (hi1 - c.y) * 1000,
                                 ringDelta.reduce(0, +) / Float(max(1, ringDelta.count)) * 1000, (ringDelta.max() ?? 0) * 1000))
                }
                // 눈 앞점 c+(0,0,r) 에 가장 가까운 패치 정점 4개: 어떤 정점이 눈 앞을 덮는지(위치·깜빡임 델타 크기)
                let front = c + SIMD3<Float>(0, 0, r)
                let nearest = (0..<min(template.patchCount, identity.positions.count)).map { ($0, simd_length(identity.positions[$0] - front)) }
                    .sorted { $0.1 < $1.1 }.prefix(4)
                print("    눈 앞점 최근접 패치 정점: " + nearest.map { v, d in
                    let p = identity.positions[v] - c
                    let dl = v < delta.count ? simd_length(delta[v]) : 0
                    return String(format: "#%d d=%.1f mm (중심 기준 x%+.1f y%+.1f z%+.1f, 깜빡임 델타 %.1f mm)", v, d * 1000, p.x * 1000, p.y * 1000, p.z * 1000, dl * 1000)
                }.joined(separator: " · "))
                print(String(format: "  눈 감기 점검 %@: 눈꺼풀 패치 정점 %d · 구면 거리 최소 뜸 %.1f / 감음 %.1f mm · 정면 덮개 뜸 %@ / 감음 %@%@",
                             name as NSString, n, minOpen * 1000, minClosed * 1000,
                             frontOpen < 0 ? "없음" : String(format: "%.1f mm", frontOpen * 1000),
                             frontClosed < 0 ? "없음(눈 앞을 덮는 눈꺼풀 정점이 없다)" : String(format: "%.1f mm", frontClosed * 1000),
                             minClosed < -0.0003 ? "  ⚠︎ 감아도 눈알이 눈꺼풀을 뚫는다" : ""))
            }
            // 실루엣 진단: 그룹별 대응 수 (어디가 깊이로 맞춰졌는지)
            if !bundle.meta.sparse {
                let aligns = FaceFitter.alignments(bundle: bundle, template: template)
                let fo = FitOptions()
                let cloud = SilhouetteFitter.buildCloud(bundle: bundle, template: template, alignments: aligns, options: fo.silhouette)
                let normals = Geometry.vertexNormals(positions: identity.positions, indices: template.indices)
                let shoulders = Set(template.manifest.group(.shoulders))
                let movable = (template.patchCount..<template.vertexCount).filter { !shoulders.contains($0) }
                let tau = SilhouetteFitter.matchTargets(cloud: cloud, positions: identity.positions, normals: normals, vertices: movable,
                                                        scalp: Set(template.manifest.group(.scalp)), neck: Set(template.manifest.group(.neck)), options: fo.silhouette)
                let matchedSet = Set(zip(movable, tau).compactMap { $1 == nil ? nil : $0 })
                print(String(format: "  실루엣 진단: 포인트 %d (머리카락/비피부 %.0f%%) · 그룹별 대응 수 / 가장 가까운 포인트 거리 중앙값(3 cm 안, 없으면 '멀다' 비율)",
                             cloud.points.count, Double(cloud.hairCount) / Double(max(1, cloud.points.count)) * 100))
                func report(_ name: String, _ ids: [Int]) {
                    let m = ids.filter { !shoulders.contains($0) && $0 >= template.patchCount }
                    guard !m.isEmpty else { return }
                    let dists = m.compactMap { cloud.nearestDistance(to: identity.positions[$0], maxRadius: 0.03) }.sorted()
                    let far = m.count - dists.count
                    print(String(format: "    %-10@ 대응 %4d/%4d · 최근접 중앙값 %5.1f mm · 3 cm 안에 포인트 없음 %.0f%%", name as NSString,
                                 m.filter { matchedSet.contains($0) }.count, m.count, dists.isEmpty ? -1 : dists[dists.count / 2] * 1000, Double(far) / Double(m.count) * 100))
                }
                for g in [VertexGroupName.scalp, .earL, .earR, .neck] { report(g.rawValue, template.manifest.group(g)) }
                let grouped = Set(template.manifest.group(.scalp) + template.manifest.group(.earL) + template.manifest.group(.earR) + template.manifest.group(.neck))
                report("기타", movable.filter { !grouped.contains($0) })
                // 깊이 정합 점검: 컷별로 **패치 정점**(ARKit 메시 그대로)이 그 컷의 깊이 포인트에서 얼마나 떨어져 있나.
                // 1–2 mm 면 깊이 → 템플릿 변환이 맞고, 10 mm 대면 깊이 intrinsics/회전이 틀린 것이다.
                for shot in bundle.shots where shot.depth != nil && shot.kind != .smile {
                    let one = CaptureBundle(meta: bundle.meta, shots: [shot])
                    let patchIDs = Array(Swift.stride(from: 0, to: template.patchCount, by: 5))
                    for registered in [false, true] {
                        var so = fo.silhouette; so.registerDepthToMesh = registered
                        let c1 = SilhouetteFitter.buildCloud(bundle: one, template: template, alignments: aligns, options: so)
                        let d = patchIDs.compactMap { c1.nearestDistance(to: identity.positions[$0], maxRadius: 0.05) }.sorted()
                        print(String(format: "    깊이 정합 %@ (%@): 포인트 %d · 패치 정점 최근접 중앙값 %.1f mm · p90 %.1f mm · 5 cm 안 없음 %d/%d",
                                     shot.kind.rawValue as NSString, registered ? "오프셋 보정" : "원본", c1.points.count, d.isEmpty ? -1 : d[d.count / 2] * 1000, d.isEmpty ? -1 : d[min(d.count - 1, d.count * 9 / 10)] * 1000,
                                     patchIDs.count - d.count, patchIDs.count))
                    }
                    // 방향: ARKit 메시 정점을 카메라로 투영한 픽셀에서 깊이를 읽어 메시의 카메라 z 와 비교 (양수 = 깊이가 메시보다 멀다)
                    if let depth = shot.depth, let Kd = shot.depthIntrinsics {
                        let faceInCam = shot.cameraTransform.inverse * shot.faceTransform
                        let raw = shot.meta.faceVertexArray
                        var diffs: [Float] = []
                        var lateral = SIMD2<Float>.zero; var nLat: Float = 0
                        for i in Swift.stride(from: 0, to: raw.count, by: 3) {
                            let pc = Geometry.transformPoint(faceInCam, raw[i])
                            guard let px = Kd.project(pc), let dz = depth.sample(px) else { continue }
                            diffs.append(dz - (-pc.z))
                            // 같은 깊이에서 가장 가까운 깊이 픽셀을 찾는 대신, 주변 ±6 px 에서 |깊이 − 메시 z| 최소인 위치의 오프셋
                            var best: Float = .greatestFiniteMagnitude; var bestOff = SIMD2<Float>.zero
                            for dy in Swift.stride(from: -12, through: 12, by: 3) { for dx in Swift.stride(from: -12, through: 12, by: 3) {
                                if let s = depth.sample(px + SIMD2(Float(dx), Float(dy))) { let e = abs(s - (-pc.z)); if e < best { best = e; bestOff = SIMD2(Float(dx), Float(dy)) } }
                            } }
                            if best < 0.004 { lateral += bestOff; nLat += 1 }
                        }
                        // 선형 회귀 depth = a + b·meshZ (스케일 오차인지 상수 오프셋인지)
                        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, nn = 0.0
                        for i in Swift.stride(from: 0, to: raw.count, by: 3) {
                            let pc = Geometry.transformPoint(faceInCam, raw[i])
                            guard let px = Kd.project(pc), let dz = depth.sample(px) else { continue }
                            let x = Double(-pc.z), y = Double(dz)
                            sx += x; sy += y; sxx += x * x; sxy += x * y; nn += 1
                        }
                        if nn > 10 {
                            let b = (nn * sxy - sx * sy) / max(1e-12, nn * sxx - sx * sx), a = (sy - b * sx) / nn
                            print(String(format: "      회귀 depth = %+.1f mm + %.3f · meshZ (평균 meshZ %.0f mm)", a * 1000, b, sx / nn * 1000))
                        }
                        diffs.sort()
                        if !diffs.isEmpty {
                            print(String(format: "      메시 정점 픽셀의 깊이 − 메시 z: 중앙값 %+.1f mm · p10 %+.1f · p90 %+.1f (n %d) · 깊이가 메시 z 와 맞는 픽셀 오프셋 평균 (%+.1f, %+.1f) px (깊이 해상도, n %.0f)",
                                         diffs[diffs.count / 2] * 1000, diffs[diffs.count / 10] * 1000, diffs[diffs.count * 9 / 10] * 1000, diffs.count,
                                         nLat > 0 ? lateral.x / nLat : 0, nLat > 0 ? lateral.y / nLat : 0, nLat))
                        }
                    }
                }
            }
            if let out {
                let aligns = FaceFitter.alignments(bundle: bundle, template: template)
                // 미소 검증 렌더의 피부는 앱과 같은 M4 `TextureBuilder`(1k, 19차 얼굴 밖 정리 포함) 로 — 전에는 11차 512² 투영기라 목·귀가 앱과 다르게 보였다
                var albedo: RGBAImage? = nil
                if let r = try? TextureBuilder.build(bundle: bundle, template: template, identity: identity, alignments: aligns, options: .preset(size: 1024)) {
                    albedo = r.albedo
                    print("텍스처(검증 렌더용): " + r.summary)
                }
                if let v = SmileVerification.make(bundle: bundle, template: template, identity: identity, alignments: aligns, albedo: albedo, width: 480) {
                    try ImageCodec.png(v.sideBySide).write(to: out)
                    print(String(format: "미소 검증(%@ 컷, 가중치 합 %.2f, %@) → %@", v.kind.title, v.weightSum,
                                 v.topShapes.map { "\($0.0.rawValue) \(String(format: "%.2f", $0.1))" }.joined(separator: " "), out.path))
                } else { print("미소 검증 렌더를 만들지 못했습니다(사진 또는 정렬 없음)") }
            }
            return 0
        } catch {
            print("실패: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            return 2
        }
    }
    var root: URL
    if first == "--synthetic" {
        guard args.count >= 2 else { print("--synthetic <출력 폴더>"); return 2 }
        root = URL(fileURLWithPath: args[args.startIndex + 1])
        do { try TemplateFolder.writeSynthetic(to: root) } catch { print("합성 템플릿 쓰기 실패: \(error)"); return 2 }
        print("합성 템플릿을 \(root.path) 에 썼습니다.")
    } else {
        root = URL(fileURLWithPath: first)
    }
    do {
        let folder = try TemplateFolder(root: root)
        var usdzPositions: [SIMD3<Float>]? = nil
        var usdzShapes: [String]? = nil
        var usdzSummary = ""
        if args.contains("--with-usdz"), folder.hasUSDZ {
            #if os(macOS)
            let url = root.appendingPathComponent(TemplateFolder.usdzName)
            let box = USDZBox()
            Task { @MainActor in
                do {
                    let (t, r, _) = try await TemplateLoader.load(url: url, manifest: folder.manifest)
                    box.positions = t?.positions; box.shapes = r.blendShapeNames; box.summary = r.summary
                } catch { box.summary = "USDZ 로드 실패: \(error.localizedDescription)" }
                box.done = true
            }
            while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            usdzPositions = box.positions; usdzShapes = box.shapes; usdzSummary = box.summary
            #else
            print("--with-usdz 는 macOS 에서만 지원합니다")
            #endif
        }
        let issues = TemplateValidator.validate(folder.validationInput(usdzPositions: usdzPositions, usdzShapeNames: usdzShapes))
        if !usdzSummary.isEmpty { print("USDZ:\n" + usdzSummary + "\n") }
        print(TemplateValidator.report(issues, title: root.lastPathComponent))
        return TemplateValidator.hasErrors(issues) ? 1 : 0
    } catch {
        print("❌ 읽기 실패: \(error.localizedDescription)\n   template.json 이 있는 Template 폴더를 지정하세요.")
        return 2
    }
}

exit(run())
