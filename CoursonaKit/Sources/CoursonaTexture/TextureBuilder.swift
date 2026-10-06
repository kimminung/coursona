//
//  TextureBuilder.swift
//  CoursonaTexture
//
//  M4 본편 (T-401 ~ T-407): 캡처 번들 + 피팅 결과 → 알베도·마스크·품질 카드. 5단계, 진행률 콜백, 2k/4k.
//   1 geometry    렌더 메시(코너 UV) UV 래스터(전체 해상도 + 저해상도 256²), 거울 삼각형, 두피·얼굴 영역, 컷 컨텍스트(카메라→템플릿, 깊이 정합, 가림 깊이 버퍼, 조명 추정)
//   2 projection  저해상도 투영(컷별 Σw·색·Σw) → 접합 게인(T-403) · 페더 마스크 · 뺨 재정규화 계수(T-404)
//   3 accumulate  전체 해상도 누적(밴드 단위): w = cos³ × 가장자리 × 깊이 일치 × 페더, 색 × 탈조명 × 게인 × 뺨 보정 (T-402)
//   4 fill        대칭 복사 → 얼굴 밖 정리(피부 게이트·저주파화·눈꺼풀/입술 안쪽 칠하기, `TextureRegions`, 19차) → 어깨·두피 채움 → pull-push (T-405)
//   5 finish      피부 양방향 필터(T-406) · mask · 품질 (관측·대칭·채움 비율, seamDelta, 시간)
//  가시성(T-401): ① 컷 카메라에서 **변형 메시의 깊이 버퍼**를 렌더해 자기 가림(코가 뺨을 가림) 을 거르고 ② 캡처 깊이(메시에 정합한 것) 와 ±허용치 일치를 소프트 가중치로.
//  CPU 참조 구현. Metal 백엔드(`MetalTextureBackend`)는 3단계와 양방향 필터를 대신한다 — 같은 수식, 256² 패리티 테스트.
//
//  C5(T-502) — 1 geometry 단계에서 `CapBuilder.addingCaps` 로 눈·입 구멍을 먼저 닫는다(`BustEntity` 가 렌더용으로
//  하는 것과 같은 패턴: 피팅된 좌표를 넣고 같은 함수를 부른다, 저장할 캡 데이터는 없다). 그래야 캡 삼각형도 이 아래의
//  일반 다중 컷 카메라 투영을 그대로 받아 눈·입 내용물이 채워진다 — 캡 전용 투영 코드가 따로 필요 없다. 구멍이 없는
//  템플릿(지금의 합성 템플릿)은 캡이 전부 nil 이라 동작이 그대로다.
//

import Foundation
import simd
import CoursonaCore
import CoursonaFace

public enum TextureStage: Int, CaseIterable, Sendable {
    case geometry = 0, projection, accumulate, fill, finish
    public var title: String {
        switch self {
        case .geometry: "기하"; case .projection: "투영·접합"; case .accumulate: "누적"; case .fill: "채움"; case .finish: "마무리"
        }
    }
}

public typealias TextureProgress = @Sendable (TextureStage, Double) -> Void

public struct TextureBuildOptions: Sendable, Equatable {
    /// 2048 또는 4096 (테스트는 작게)
    public var size = 2048
    /// 텍셀당 n×n 부표본 (footprint 적분). 2k/4k 는 1
    public var supersample = 1
    /// 캡처 깊이 일치 허용 (m). 깊이를 메시에 정합하므로 15 mm 로 돌아간다(M4 1차는 35 mm)
    public var depthTolerance: Float = 0.015
    /// 자기 가림 허용 (m)
    public var occlusionTolerance: Float = 0.006
    public var registerDepthToMesh = true
    /// 탈조명 강도 0…1 (0 = 원본 그대로)
    public var delight: Float = 0.5
    /// 뺨 기준 재정규화 (정면 컷 뺨 평균색을 탈조명 전과 같게). **기본 꺼짐** — 램버트 탈조명은 스칼라 배율이라 색도는 못 바꾸고,
    /// 이 보정은 밝아진 그늘을 도로 어둡게 할 뿐이었다(합성 PSNR 20 → 13 dB). 피부톤 조절은 강도 슬라이더로.
    public var cheekRenormalize = false
    public var seamCorrection = true
    public var seamGrid = 32
    /// 페더 폭 (저해상도 셀 수; 저해상도 256² 기준 2 셀 ≈ 전체 해상도 2k 에서 16 텍셀)
    public var featherCells: Float = 2
    public var excludeMouthInSmile = true
    public var mirrorFill = true
    public var scalpHairFill = true
    public var pullPush = true
    public var skinFilter = true
    public var skinSigmaTexels: Float = 3
    public var skinSigmaColor: Float = 0.08
    public var lowResSize = 256
    /// 얼굴 패치 밖 피부 부위(목·귀·머리 옆) 의 관측 정리 (`TextureRegions`): 피부 게이트 + 저주파화. 두피는 머리카락 기준색으로 같은 처리.
    public var softRegions = true
    /// 저주파화 σ — 2k 기준 텍셀 수(해상도에 비례해 줄인다). 24 ≈ 목 둘레 2–3 cm
    public var softSigmaTexels2k: Float = 24
    /// 저주파화 결과를 얼굴 피부 기준색 쪽으로 섞는 비율 (목·귀 색조를 얼굴과 맞춘다)
    public var softSkinBlend: Float = 0.2
    /// 저주파 커버리지 하한 — 이보다 성기면 비워서 pull-push 가 이웃색으로 메운다
    public var softMinCoverage: Float = 0.12
    /// Metal 백엔드 사용 (없거나 실패하면 CPU)
    public var preferMetal = true
    /// C5(T-501) `faceOnly` 프리셋: 얼굴 패치·눈꺼풀/입술 안쪽·캡 섬만 전체 해상도로 투영하고, 나머지(두피·목·어깨)는
    /// 이 단계에서 아예 건너뛴다(4단계의 기존 채움 로직이 메운다 — 새 채움 코드가 필요 없다). 나머지 영역 색은
    /// `TextureBuildResult.splatColor`(저해상도, 스플랫 초기화용, `splatColorSize`)로 따로 낸다 — 얼굴 쪽
    /// `lowResSize`(접합·페더용, 기본 256) 와는 별개 해상도라 서로 안 건드린다. **Metal 백엔드는 이 옵션을 모른다** —
    /// 켜져 있으면 패리티가 깨지므로 CPU 로 강제한다(성능은 어차피 얼굴만 돌려서 전체보다 빠르다).
    public var faceOnly = false
    /// §6.5: 나머지 영역 스플랫 색 추출용 한 장의 크기(기본 512²).
    public var splatColorSize = 512
    public init() {}
    public static func preset(size: Int) -> TextureBuildOptions { var o = TextureBuildOptions(); o.size = size; return o }
    public static func faceOnlyPreset(size: Int = 2048, splatColorSize: Int = 512) -> TextureBuildOptions {
        var o = TextureBuildOptions(); o.size = size; o.faceOnly = true; o.splatColorSize = splatColorSize; return o
    }
}

public struct TextureBuildResult: Sendable {
    public var albedo: RGBAImage
    public var mask: RGBAImage
    public var quality: TextureQuality
    public var usedShots: [ShotKind]
    public var lights: [ShotKind: LightEstimateResult]
    public var depthOffsets: [ShotKind: Float]
    public var seamDeltaBefore: Float
    public var cheekGain: SIMD3<Float>
    public var hairColor: SIMD3<Float>?
    /// 얼굴 패치 관측 중앙값 (목·귀 게이트·눈꺼풀 안쪽 채움의 기준). 얼굴 관측이 없으면 nil
    public var skinColor: SIMD3<Float>? = nil
    /// 피부·머리카락 게이트와 저주파 커버리지 부족으로 버린 관측 텍셀 수
    public var rejectedTexels = 0
    public var stageSeconds: [Double]
    public var backend: String
    /// C5(T-501) `faceOnly` 일 때만: 얼굴 밖(두피·목·어깨) 색 — 스플랫 초기화용 저해상도 한 장. 평소엔 nil.
    public var splatColor: RGBAImage? = nil
    public var summary: String {
        String(format: "%d² · 관측 %.0f%% · 대칭 %.0f%% · 채움 %.0f%% · 접합 %.1f→%.1f/255 · %.1f s (%@)",
               albedo.width, quality.observedRatio * 100, quality.mirroredRatio * 100, quality.filledRatio * 100,
               seamDeltaBefore, quality.seamDelta, quality.buildSeconds, backend)
    }
}

public enum TextureBuildError: Error, LocalizedError {
    case noUsableShots
    public var errorDescription: String? { "텍스처를 만들 컷이 없습니다 (사진이 없거나 정렬에 실패했습니다)" }
}

/// 컷 하나의 투영 컨텍스트 (템플릿 공간).
public struct ShotContext: Sendable {
    public var kind: ShotKind
    public var image: RGBAImage
    public var K: Geometry.Intrinsics
    public var depth: DepthMap?
    public var Kd: Geometry.Intrinsics?
    public var worldToCamera: simd_float4x4
    public var cameraPosition: SIMD3<Float>
    /// 자기 가림용 깊이 버퍼 (카메라 거리, 메시 렌더) + 그 intrinsics
    public var occlusion: DepthMap
    public var Ko: Geometry.Intrinsics
    public var light: LightEstimateResult?
    public var isSmile: Bool
    public var depthOffset: Float
}

public enum TextureBuilder {
    // MARK: 진입

    public static func build(bundle: CaptureBundle, template t: BustTemplate, identity: Identity, alignments: [ShotKind: simd_float4x4],
                             options o: TextureBuildOptions = TextureBuildOptions(), progress: TextureProgress? = nil) throws -> TextureBuildResult {
        let t0 = Date()
        var stageSeconds: [Double] = []
        func tick(_ s: TextureStage, _ f: Double) { progress?(s, f) }
        var last = Date()
        func stageDone() { stageSeconds.append(Date().timeIntervalSince(last)); last = Date() }

        // ---- 1 geometry ------------------------------------------------------------------
        tick(.geometry, 0)
        // C5(T-502): 피팅된 좌표를 넣고 눈·입 구멍을 먼저 닫는다(`BustEntity` 와 같은 패턴) — 이 아래부터는
        // `t` 가 캡이 닫힌 템플릿을 가리킨다. 구멍이 없으면(지금의 합성 템플릿) 캡이 전부 nil 이라 그대로다.
        var fittedForCaps = t
        if identity.positions.count == t.vertexCount { fittedForCaps.positions = identity.positions }
        let capResult = CapBuilder.addingCaps(to: fittedForCaps)
        let t = capResult.template
        let render = t.makeRenderMesh()
        let rPos = render.expand(t.positions)
        let rNrm = Geometry.vertexNormals(positions: rPos, indices: render.indices)
        let S = o.size
        let raster = TexelRaster(render: render, size: S, supersample: o.supersample)
        tick(.geometry, 0.4)
        let L = o.lowResSize
        let lowRaster = TexelRaster(render: render, size: L, supersample: 1)
        let mirror = TextureFill.mirrorTriangles(render: render, symmetryMap: t.manifest.symmetryMap)
        let scalpSet = Set(t.manifest.group(.scalp))
        let triScalp: [Bool] = (0..<(render.indices.count / 3)).map { tri in
            (0..<3).allSatisfy { scalpSet.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) }
        }
        // Shoulders 그룹은 Shoulders_<id> 옷 라이브러리 오브젝트에 가려질 Bust 자체 어깨 셀이다. 아직 옷 오브젝트를 붙이지 않아 늘 맨살처럼 보이는데,
        // 사용자는 항상 옷을 입고 촬영하므로 직접 투영하면 깊이·법선이 옷과도 잘 맞아 셔츠 색이 "피부"로 관측된다(실기기 2k 알베도에서 확인).
        // 관측을 버리고 Neck 관측 평균(피부색)으로 채운다(아래 "4 fill").
        let shoulderSet = Set(t.manifest.group(.shoulders))
        let triShoulders: [Bool] = (0..<(render.indices.count / 3)).map { tri in
            (0..<3).allSatisfy { shoulderSet.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) }
        }
        let neckSet = Set(t.manifest.group(.neck))
        let triNeckOnly: [Bool] = (0..<(render.indices.count / 3)).map { tri in
            guard !triShoulders[tri] else { return false }
            return (0..<3).allSatisfy { neckSet.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) }
        }
        // 영역 분류(19차, `TextureRegions`): 얼굴 패치(세 정점 모두 패치) · 눈꺼풀 안쪽 · 입술 안쪽 · "부드러운 피부"(패치·두피·어깨·안쪽 띠가 아닌 전부 = 목·귀·머리 옆)
        func triAll(_ set: Set<Int>) -> [Bool] {
            (0..<(render.indices.count / 3)).map { tri in (0..<3).allSatisfy { set.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) } }
        }
        let triPatch = triAll(Set(0..<t.patchCount))
        let triLidInner = triAll(Set(t.manifest.group(.lidInner)))
        let triLipInner = triAll(Set(t.manifest.group(.lipInner)))
        let triSoftSkin: [Bool] = (0..<(render.indices.count / 3)).map { tri in
            !triPatch[tri] && !triScalp[tri] && !triShoulders[tri] && !triLidInner[tri] && !triLipInner[tri]
        }
        // C5(T-501) faceOnly: 캡(눈·입) 삼각형은 `capResult` 가 가진 구간(정점 id 3개 단위, `makeRenderMesh` 가
        // 삼각형 순서를 보존하므로 render mesh 에서도 같은 삼각형 번호)으로 바로 안다 — 새로 분류할 필요가 없다.
        let capTriRanges: [Range<Int>] = capResult.caps.map { $0.triangleIndexRange.lowerBound / 3 ..< $0.triangleIndexRange.upperBound / 3 }
        let isFaceTri: [Bool] = (0..<(render.indices.count / 3)).map { tri in
            triPatch[tri] || triLidInner[tri] || triLipInner[tri] || capTriRanges.contains { $0.contains(tri) }
        }
        let mouthUV: SIMD2<Float>? = t.manifest.landmark(.lipUpperMid).flatMap { srcID in
            render.sourceIndex.firstIndex(of: Int32(srcID)).map { render.uvs[$0] }
        }
        let faceRegion = t.manifest.uvRegions["face"].flatMap { $0.count == 4 ? $0 : nil } ?? [0, 0, 1, 0.5]
        let cheek = TextureLighting.cheekVertices(template: t)
        let cheekTris: Set<Int32> = {
            let cs = Set(cheek)
            var out = Set<Int32>()
            for tri in 0..<(render.indices.count / 3) where (0..<3).allSatisfy({ cs.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) }) { out.insert(Int32(tri)) }
            return out
        }()
        tick(.geometry, 0.6)
        let shots = try makeContexts(bundle: bundle, template: t, alignments: alignments, render: render, positions: rPos, normals: rNrm, options: o)
        let anchor = shots.firstIndex { $0.kind == .front } ?? 0
        stageDone(); tick(.geometry, 1)

        // ---- 2 projection (저해상도) ---------------------------------------------------------
        tick(.projection, 0)
        let ns = shots.count
        var lowColor = [[SIMD3<Float>]](repeating: [SIMD3<Float>](repeating: .zero, count: L * L), count: ns)
        var lowWeight = [[Float]](repeating: [Float](repeating: 0, count: L * L), count: ns)
        var cheekRaw = SIMD3<Float>.zero, cheekDelit = SIMD3<Float>.zero, cheekN: Float = 0
        for i in 0..<(L * L) {
            guard let g = lowRaster.interpolate(i, positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices) else { continue }
            for (s, ctx) in shots.enumerated() {
                guard let smp = sample(ctx, pos: g.pos, nrm: g.nrm, uv: g.uv, mouthUV: mouthUV, o: o) else { continue }
                let f = TextureLighting.delightFactor(shade: smp.shade, strength: o.delight)
                let col = simd_min(SIMD3(repeating: 1), smp.color * f)
                lowColor[s][i] += col * smp.weight; lowWeight[s][i] += smp.weight
                if s == anchor, cheekTris.contains(lowRaster.triID[i]) { cheekRaw += smp.color; cheekDelit += col; cheekN += 1 }
            }
        }
        tick(.projection, 0.5)
        let gains = o.seamCorrection ? TextureSeams.solve(colorSum: lowColor, weight: lowWeight, lowRes: L, grid: o.seamGrid, anchorShot: anchor)
                                     : .identity(grid: o.seamGrid, shots: ns)
        // 페더: 저해상도 가시성 마스크의 경계 거리 (셀 단위)
        let feather = shots.indices.map { s in featherMask(weights: lowWeight[s], size: L, radius: o.featherCells) }
        var cheekGain = SIMD3<Float>(repeating: 1)
        if o.cheekRenormalize, cheekN >= 10, o.delight > 0 {
            cheekGain = simd_clamp(cheekRaw / simd_max(SIMD3(repeating: 1e-4), cheekDelit), SIMD3(repeating: 0.5), SIMD3(repeating: 2))
        }
        // C5(T-501) faceOnly: 얼굴 밖(두피·목·어깨) 색을 한 장(기본 512²) 뽑는다 — 스플랫 초기화용이라
        // 접합·페더 보정 없이 컷 가중 평균만 쓴다(§6.5, 연속 표면이 아니라 삼각형별 이산 스플랫이라 이음매가 안 보인다).
        var splatColor: RGBAImage? = nil
        if o.faceOnly {
            let sz = max(16, o.splatColorSize)
            let splatRaster = TexelRaster(render: render, size: sz, supersample: 1)
            var img = RGBAImage(width: sz, height: sz, fill: SIMD4(0, 0, 0, 0))
            for i in 0..<(sz * sz) {
                guard let g = splatRaster.interpolate(i, positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices) else { continue }
                var acc = SIMD3<Float>.zero, wsum: Float = 0
                for ctx in shots {
                    guard let smp = sample(ctx, pos: g.pos, nrm: g.nrm, uv: g.uv, mouthUV: mouthUV, o: o) else { continue }
                    let f = TextureLighting.delightFactor(shade: smp.shade, strength: o.delight)
                    acc += simd_min(SIMD3(repeating: 1), smp.color * f) * smp.weight; wsum += smp.weight
                }
                guard wsum > 0 else { continue }
                let c = simd_clamp(acc / wsum, .zero, SIMD3(repeating: 1))
                img[i % sz, i / sz] = SIMD4(UInt8(c.x * 255), UInt8(c.y * 255), UInt8(c.z * 255), 255)
            }
            splatColor = img
        }
        stageDone(); tick(.projection, 1)

        // ---- 3 accumulate (전체 해상도) ------------------------------------------------------
        tick(.accumulate, 0)
        var albedo = [SIMD3<Float>](repeating: .zero, count: S * S)
        var state = [UInt8](repeating: 0, count: S * S)
        var inside = [Bool](repeating: false, count: S * S)
        var isScalp = [Bool](repeating: false, count: S * S)
        var isShoulders = [Bool](repeating: false, count: S * S)
        var isNeckOnly = [Bool](repeating: false, count: S * S)
        var isPatch = [Bool](repeating: false, count: S * S)
        var isLidInner = [Bool](repeating: false, count: S * S)
        var isLipInner = [Bool](repeating: false, count: S * S)
        var isSoftSkin = [Bool](repeating: false, count: S * S)
        var inFace = [Bool](repeating: false, count: S * S)
        let ssn = raster.supersample, G = raster.grid
        var backend = "CPU"
        var accumulated = false
        #if canImport(Metal)
        // faceOnly 는 Metal 커널이 모르는 옵션이라(얼굴 밖 건너뛰기) CPU 로 강제한다 — 안 그러면 패리티가 깨진다.
        if o.preferMetal, !o.faceOnly, let gpu = MetalTextureBackend.shared {
            do {
                try gpu.accumulate(raster: raster, render: render, positions: rPos, normals: rNrm, shots: shots, gains: gains, feather: feather,
                                   mouthUV: mouthUV, cheekGain: cheekGain, options: o, albedo: &albedo, state: &state) { f in tick(.accumulate, f * 0.9) }
                backend = "Metal"
                accumulated = true
            } catch {
                backend = "CPU (Metal 실패: \(error.localizedDescription))"
            }
        }
        #endif
        if !accumulated {
            let band = max(16, 1 << 20 / S)   // 밴드 행 수 (≈1M 텍셀)
            var y0 = 0
            while y0 < S {
                let y1 = min(S, y0 + band)
                for y in y0..<y1 {
                    for x in 0..<S {
                        var acc = SIMD3<Float>.zero, wsum: Float = 0
                        for sy in 0..<ssn { for sx in 0..<ssn {
                            let k = (y * ssn + sy) * G + (x * ssn + sx)
                            // faceOnly: 얼굴 밖 삼각형은 다중 컷 샘플링을 아예 생략한다 — "관측 없음" 으로 남아
                            // 4단계(기존 채움: 두피 평균·목 피부색·어깨→목)가 그대로 메운다, 새 코드 없이.
                            if o.faceOnly {
                                let tri = Int(raster.triID[k])
                                guard tri >= 0, isFaceTri[tri] else { continue }
                            }
                            guard let g = raster.interpolate(k, positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices) else { continue }
                            for (s, ctx) in shots.enumerated() {
                                guard let smp = sample(ctx, pos: g.pos, nrm: g.nrm, uv: g.uv, mouthUV: mouthUV, o: o) else { continue }
                                let fe = featherAt(feather[s], size: L, u: g.uv.x, v: g.uv.y)
                                guard fe > 0 else { continue }
                                let f = TextureLighting.delightFactor(shade: smp.shade, strength: o.delight)
                                let col = simd_min(SIMD3(repeating: 1), smp.color * f * cheekGain) * gains.gain(shot: s, u: g.uv.x, v: g.uv.y)
                                let w = smp.weight * fe
                                acc += col * w; wsum += w
                            }
                        } }
                        let i = y * S + x
                        if wsum > 0 { albedo[i] = simd_min(SIMD3(repeating: 1), acc / wsum); state[i] = TextureFill.TexelState.observed.rawValue }
                    }
                }
                tick(.accumulate, Double(y1) / Double(S) * 0.9)
                y0 = y1
            }
        }
        for y in 0..<S { for x in 0..<S {
            let i = y * S + x
            let tri = raster.representativeTriangle(x: x, y: y)
            inside[i] = tri >= 0
            isScalp[i] = tri >= 0 && triScalp[Int(tri)]
            isShoulders[i] = tri >= 0 && triShoulders[Int(tri)]
            isNeckOnly[i] = tri >= 0 && triNeckOnly[Int(tri)]
            isPatch[i] = tri >= 0 && triPatch[Int(tri)]
            isLidInner[i] = tri >= 0 && triLidInner[Int(tri)]
            isLipInner[i] = tri >= 0 && triLipInner[Int(tri)]
            isSoftSkin[i] = tri >= 0 && triSoftSkin[Int(tri)]
            let u = (Float(x) + 0.5) / Float(S), v = 1 - (Float(y) + 0.5) / Float(S)
            inFace[i] = u >= faceRegion[0] && u <= faceRegion[2] && v >= faceRegion[1] && v <= faceRegion[3]
        } }
        // Shoulders 는 항상 옷으로 가려지므로 방금 누적한 관측(실제로는 셔츠 색)을 버린다 — 아래 "4 fill" 에서 Neck 평균으로 다시 채운다.
        for i in 0..<(S * S) where isShoulders[i] {
            albedo[i] = .zero
            state[i] = TextureFill.TexelState.empty.rawValue
        }
        stageDone(); tick(.accumulate, 1)

        // ---- 4 fill -------------------------------------------------------------------------
        tick(.fill, 0)
        var mirrored = 0, filled = 0
        var hair: SIMD3<Float>? = nil
        // 대표 삼각형 래스터 (텍셀 단위) — 대칭 복사용
        let texTri: [Int32] = (0..<(S * S)).map { raster.representativeTriangle(x: $0 % S, y: $0 / S) }
        let texBary: [SIMD2<UInt16>] = (0..<(S * S)).map { i -> SIMD2<UInt16> in
            let x = i % S, y = i / S
            for sy in 0..<ssn { for sx in 0..<ssn { let k = (y * ssn + sy) * G + (x * ssn + sx); if raster.triID[k] >= 0 { return raster.bary[k] } } }
            return .zero
        }
        if o.mirrorFill {
            mirrored = TextureFill.mirrorCopy(albedo: &albedo, state: &state, size: S, triID: texTri, bary: texBary, render: render, mirror: mirror)
        }
        // 얼굴 패치 밖 정리 (`TextureRegions` 머리말 참고) — 대칭 복사 뒤에 둬서 복사본도 같은 게이트·저주파화를 받는다. 피부 기준색은 얼굴 패치 관측 중앙값 — 18차의 "Neck 은 R > B" 규칙을 대체한다
        // (그 규칙은 청/회색 옷만 걸렀고 흰 깃·하이라이트·머리카락·깊은 그늘은 통과시켜 목이 조각나 보였다).
        let skin = TextureRegions.medianColor(albedo: albedo, state: state, mask: isPatch)
        var rejected = 0
        if o.softRegions {
            let cell = max(1, S / 256), sigmaCells = max(0.5, o.softSigmaTexels2k * Float(S) / 2048 / Float(cell))
            if let skin {
                rejected += TextureRegions.rejectNonSkin(albedo: &albedo, state: &state, mask: isSoftSkin, reference: skin, gate: .skin)
            }
            let soft = TextureRegions.lowPass(albedo: &albedo, state: &state, mask: isSoftSkin, size: S, cell: cell, sigmaCells: sigmaCells,
                                              minCoverage: o.softMinCoverage, blendTo: skin, blend: skin == nil ? 0 : o.softSkinBlend)
            rejected += soft.cleared
            if let hairRef = TextureRegions.medianColor(albedo: albedo, state: state, mask: isScalp) {
                rejected += TextureRegions.rejectNonSkin(albedo: &albedo, state: &state, mask: isScalp, reference: hairRef, gate: .hair)
            }
            rejected += TextureRegions.lowPass(albedo: &albedo, state: &state, mask: isScalp, size: S, cell: cell, sigmaCells: sigmaCells,
                                               minCoverage: o.softMinCoverage).cleared
        }
        // 눈꺼풀·입술 안쪽 띠: 카메라는 그 자리에서 눈알·치아를 본다 → 관측을 버리고 피부·입술색에서 유도한 색으로 칠한다.
        if let skin {
            TextureRegions.paint(albedo: &albedo, state: &state, mask: isLidInner, color: skin * SIMD3(0.85, 0.70, 0.70))
            let lip = mouthUV.flatMap { TextureRegions.lipColor(albedo: albedo, state: state, faceMask: isPatch, size: S, mouthUV: $0, radius: 0.02) }
                ?? skin * SIMD3(0.8, 0.5, 0.5)
            TextureRegions.paint(albedo: &albedo, state: &state, mask: isLipInner, color: lip * 0.45)
        }
        // Shoulders 는 늘 옷에 가려 직접 관측을 못 믿으므로(위 "3 accumulate" 에서 버림) Neck 평균(피부색)으로 채운다.
        // 셀카류 조명은 턱 밑(목 바로 위)이 자기 그림자로 유독 어둡게 찍히기 쉬운데, 그 평균을 그대로 어깨 전체에
        // 칠하면 실제 피부색이 아니라 그림자가 넓게 번져 검은 얼룩처럼 보인다(실기기 스크린샷으로 확인한 회귀).
        // 평균 밝기가 피부로 보기엔 비정상적으로 낮을 때만 최소 밝기로 끌어올린다 — 정상적인(그림자 없는) 짙은
        // 피부톤의 목 평균은 이 정도로 어둡지 않으므로 오탐 가능성은 낮다.
        let (shoulderFilled, neckAvg) = TextureFill.fillUniform(albedo: &albedo, state: &state, sourceMask: isNeckOnly, targetMask: isShoulders)
        if let avg = neckAvg {
            let luma = simd_dot(avg, SIMD3<Float>(0.2126, 0.7152, 0.0722))
            let minLuma: Float = 0.12
            if luma > 1e-4, luma < minLuma {
                let boosted = avg * (minLuma / luma)
                for i in albedo.indices where isShoulders[i] && state[i] == TextureFill.TexelState.filled.rawValue { albedo[i] = boosted }
            }
        }
        filled += shoulderFilled
        tick(.fill, 0.4)
        if o.scalpHairFill {
            let (n, h) = TextureFill.fillScalp(albedo: &albedo, state: &state, isScalp: isScalp)
            filled += n; hair = h
        }
        if o.pullPush { filled += TextureFill.pullPush(albedo: &albedo, state: &state, inside: inside, size: S) }
        stageDone(); tick(.fill, 1)

        // ---- 5 finish ------------------------------------------------------------------------
        tick(.finish, 0)
        if o.skinFilter {
            let apply = (0..<(S * S)).map { inFace[$0] && (state[$0] == 1 || state[$0] == 2) }
            var done = false
            #if canImport(Metal)
            if o.preferMetal, let gpu = MetalTextureBackend.shared, (try? gpu.bilateral(albedo: &albedo, apply: apply, size: S, sigmaSpace: o.skinSigmaTexels, sigmaColor: o.skinSigmaColor)) != nil { done = true }
            #endif
            if !done { TextureFill.bilateral(albedo: &albedo, apply: apply, size: S, sigmaSpace: o.skinSigmaTexels, sigmaColor: o.skinSigmaColor) }
        }
        tick(.finish, 0.7)
        var outAlbedo = RGBAImage(width: S, height: S, fill: SIMD4(0, 0, 0, 255))
        var outMask = RGBAImage(width: S, height: S, fill: SIMD4(0, 0, 0, 255))
        var observed = 0, insideCount = 0
        for i in 0..<(S * S) {
            let c = albedo[i]
            outAlbedo.bytes[i * 4] = UInt8(min(255, max(0, c.x * 255 + 0.5)))
            outAlbedo.bytes[i * 4 + 1] = UInt8(min(255, max(0, c.y * 255 + 0.5)))
            outAlbedo.bytes[i * 4 + 2] = UInt8(min(255, max(0, c.z * 255 + 0.5)))
            switch state[i] {
            case 1: outMask.bytes[i * 4] = 255; observed += 1
            case 2: outMask.bytes[i * 4 + 1] = 255
            case 3: outMask.bytes[i * 4 + 2] = 255
            default: break
            }
            if inside[i] { insideCount += 1 }
        }
        stageDone(); tick(.finish, 1)
        let total = Date().timeIntervalSince(t0)
        let q = TextureQuality(observedRatio: insideCount > 0 ? Float(observed) / Float(insideCount) : 0,
                               mirroredRatio: insideCount > 0 ? Float(mirrored) / Float(insideCount) : 0,
                               filledRatio: insideCount > 0 ? Float(filled) / Float(insideCount) : 0,
                               seamDelta: gains.seamDeltaAfter, buildSeconds: total)
        var lights: [ShotKind: LightEstimateResult] = [:], offsets: [ShotKind: Float] = [:]
        for c in shots { lights[c.kind] = c.light; if c.depth != nil { offsets[c.kind] = c.depthOffset } }
        return TextureBuildResult(albedo: outAlbedo, mask: outMask, quality: q, usedShots: shots.map(\.kind), lights: lights, depthOffsets: offsets,
                                  seamDeltaBefore: gains.seamDeltaBefore, cheekGain: cheekGain, hairColor: hair, skinColor: skin, rejectedTexels: rejected,
                                  stageSeconds: stageSeconds, backend: backend, splatColor: splatColor)
    }

    // MARK: 컷 컨텍스트

    /// 컷별 투영 컨텍스트: 카메라 → 템플릿, 깊이 정합, 자기 가림 깊이 버퍼(사진 1/2 해상도 렌더), 조명 추정(주변광 비율은 컷 중앙값으로 통일).
    public static func makeContexts(bundle: CaptureBundle, template t: BustTemplate, alignments: [ShotKind: simd_float4x4],
                                    render: BustTemplate.RenderMesh, positions rPos: [SIMD3<Float>], normals rNrm: [SIMD3<Float>],
                                    options o: TextureBuildOptions) throws -> [ShotContext] {
        var shots: [ShotContext] = []
        for shot in bundle.shots {
            guard let img = shot.image, let F = alignments[shot.kind] else { continue }
            let M = F * shot.faceTransform.inverse * shot.cameraTransform
            let camPos = SIMD3(M.columns.3.x, M.columns.3.y, M.columns.3.z)
            var depth = shot.depth
            var offset: Float = 0
            if o.registerDepthToMesh, let d = depth, let reg = DepthRegistration.estimate(shot: shot, template: t) {
                depth = DepthRegistration.corrected(d, offset: reg.offset); offset = reg.offset
            }
            let ow = max(64, img.width / 2), oh = max(64, img.height / 2)
            let Ko = shot.meta.intrinsics.scaled(toWidth: ow, height: oh)
            let occ = SoftwareRasterizer.render(positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices,
                                                camera: RenderCamera(intrinsics: Ko, transform: M), width: ow, height: oh) { _, _, _ in SIMD3(repeating: 0.5) }.depth
            let light = TextureLighting.estimate(shot: shot, template: t, faceToTemplate: F, cameraToTemplate: M)
                ?? TextureLighting.fromARKit(shot: shot, faceToTemplate: F)
            shots.append(ShotContext(kind: shot.kind, image: img, K: shot.meta.intrinsics.scaled(toWidth: img.width, height: img.height),
                                     depth: depth, Kd: depth.map { shot.meta.intrinsics.scaled(toWidth: $0.width, height: $0.height) },
                                     worldToCamera: M.inverse, cameraPosition: camPos, occlusion: occ, Ko: Ko, light: light,
                                     isSmile: shot.kind == .smile, depthOffset: offset))
        }
        guard !shots.isEmpty else { throw TextureBuildError.noUsableShots }
        // 주변광 비율 f 는 장면의 성질이라 컷마다 다를 이유가 없다 → 얼굴에서 추정한 값들의 중앙값으로 통일(방향은 컷별 유지).
        // 컷별 f 가 0.28–0.40 으로 흔들리면 그늘(1/f 배)에서 10 % 넘게 틀린다(합성 두상 23 dB → 통일 후 개선).
        let fs = shots.compactMap { $0.light?.source == "face" ? $0.light?.ambientFraction : nil }.sorted()
        if fs.count >= 2 {
            let med = fs[fs.count / 2]
            for i in shots.indices where shots[i].light?.source == "face" { shots[i].light?.ambientFraction = med }
        }
        return shots
    }

    /// 진단: 텍셀 UV 하나에 어느 컷의 어떤 표본이 들어오는지 (CLI `--texture … probe=u,v`).
    public static func probe(bundle: CaptureBundle, template t: BustTemplate, identity: Identity, alignments: [ShotKind: simd_float4x4],
                             uv: SIMD2<Float>, options o: TextureBuildOptions) throws -> [String] {
        var fittedForCaps = t
        if identity.positions.count == t.vertexCount { fittedForCaps.positions = identity.positions }
        let t = CapBuilder.addingCaps(to: fittedForCaps).template
        let render = t.makeRenderMesh()
        let rPos = render.expand(t.positions)
        let rNrm = Geometry.vertexNormals(positions: rPos, indices: render.indices)
        let shots = try makeContexts(bundle: bundle, template: t, alignments: alignments, render: render, positions: rPos, normals: rNrm, options: o)
        let S = 512
        let raster = TexelRaster(render: render, size: S)
        let x = min(S - 1, Int(uv.x * Float(S))), y = min(S - 1, Int((1 - uv.y) * Float(S)))
        guard let g = raster.interpolate(y * S + x, positions: rPos, normals: rNrm, uvs: render.uvs, indices: render.indices) else { return ["텍셀 밖 (삼각형 없음)"] }
        let tri = raster.triID[y * S + x]
        let srcVerts = (0..<3).map { Int(render.sourceIndex[Int(render.indices[Int(tri) * 3 + $0])]) }
        var lines = [String(format: "uv(%.3f, %.3f) 삼각형 %d 원본 정점 %@ 위치 (%.3f, %.3f, %.3f) 법선 (%.2f, %.2f, %.2f)", uv.x, uv.y, tri, "\(srcVerts)", g.pos.x, g.pos.y, g.pos.z, g.nrm.x, g.nrm.y, g.nrm.z)]
        for g2 in [VertexGroupName.scalp, .neck, .shoulders, .earL, .earR] where srcVerts.allSatisfy({ t.manifest.group(g2).contains($0) }) { lines.append("  그룹 \(g2.rawValue)") }
        for c in shots {
            let pc = Geometry.transformPoint(c.worldToCamera, g.pos)
            let px = c.K.project(pc)
            let cosv = simd_dot(g.nrm, simd_normalize(c.cameraPosition - g.pos))
            var s = String(format: "  %@: 픽셀 %@ · 카메라 z %.3f · cos %.2f", c.kind.rawValue as NSString, px.map { String(format: "(%.0f, %.0f)", $0.x, $0.y) } ?? "뒤" as String, -pc.z, cosv)
            if let po = c.Ko.project(pc), let zr = c.occlusion.sample(po) { s += String(format: " · 가림 깊이 %.3f", zr) }
            if let d = c.depth, let Kd = c.Kd, let pd = Kd.project(pc) { s += d.sample(pd).map { String(format: " · 캡처 깊이 %.3f", $0) } ?? " · 캡처 깊이 없음" }
            if let smp = sample(c, pos: g.pos, nrm: g.nrm, uv: g.uv, mouthUV: nil, o: o) {
                s += String(format: " → 채택 w %.3f 색 (%.0f, %.0f, %.0f) shade %.2f", smp.weight, smp.color.x * 255, smp.color.y * 255, smp.color.z * 255, smp.shade)
            } else { s += " → 거부" }
            lines.append(s)
        }
        return lines
    }

    // MARK: 표본

    public struct Sample { public var color: SIMD3<Float>; public var weight: Float; public var shade: Float }

    /// 한 컷에서 텍셀 표본: 가시성·깊이·가림 검사 후 색·가중치·음영. 보이지 않으면 nil.
    @inline(__always)
    public static func sample(_ c: ShotContext, pos: SIMD3<Float>, nrm: SIMD3<Float>, uv: SIMD2<Float>, mouthUV: SIMD2<Float>?, o: TextureBuildOptions) -> Sample? {
        if c.isSmile, o.excludeMouthInSmile, let m = mouthUV, simd_length(uv - m) < 0.12 { return nil }
        let pc = Geometry.transformPoint(c.worldToCamera, pos)
        guard let px = c.K.project(pc) else { return nil }
        guard px.x >= 1, px.y >= 1, px.x < Float(c.image.width - 1), px.y < Float(c.image.height - 1) else { return nil }
        let viewDir = simd_normalize(c.cameraPosition - pos)
        let cosv = simd_dot(nrm, viewDir)
        // 0.08(85°) 는 너무 느슨해 거의 접선인 뷰까지 받아들인다 — 그런 각에선 위치·캘리브레이션 오차가 커지고,
        // 목/어깨처럼 실루엣 가장자리인 부위는 그 각도에서 카메라가 피부 대신 옷을 보는 경우가 많다(실기기 알베도에서 확인).
        guard cosv > 0.3 else { return nil }
        let zc = -pc.z
        // 자기 가림
        if let po = c.Ko.project(pc), let zr = c.occlusion.sample(po), zc > zr + o.occlusionTolerance { return nil }
        // 캡처 깊이 일치 (소프트). 깊이 맵이 있는데 그 픽셀에 깊이가 **없으면 배경**(TrueDepth 측정 범위 밖)이라 버린다 —
        // 안 그러면 템플릿 두상이 사용자 머리 밖으로 삐져나온 곳에 창문·벽 색이 관측으로 들어온다(실기기 2k 알베도에서 확인).
        var wd: Float = 1
        if let d = c.depth, let Kd = c.Kd {
            guard let pd = Kd.project(pc), let captured = d.sample(pd) else { return nil }
            let dz = abs(captured - zc)
            guard dz < 2 * o.depthTolerance else { return nil }
            wd = exp(-(dz * dz) / (o.depthTolerance * o.depthTolerance))
        }
        guard let col = c.image.sample(px) else { return nil }
        let ex = min(px.x, Float(c.image.width) - px.x) / Float(c.image.width), ey = min(px.y, Float(c.image.height) - px.y) / Float(c.image.height)
        let edge = min(1, min(ex, ey) / 0.08)
        let w = cosv * cosv * cosv * edge * wd
        var shade: Float = 1
        if let l = c.light, l.contrast >= TextureLighting.minContrast { shade = TextureLighting.shade(normal: nrm, light: l) }
        return Sample(color: SIMD3(col.x, col.y, col.z), weight: w, shade: shade)
    }

    // MARK: 페더

    /// 저해상도 가시성 마스크 → 경계까지의 거리(셀) / radius 로 0…1 (체비셰프 거리, radius 셀 안만 본다).
    static func featherMask(weights: [Float], size L: Int, radius: Float) -> [Float] {
        let r = max(1, Int(radius.rounded(.up)))
        var out = [Float](repeating: 0, count: L * L)
        for y in 0..<L { for x in 0..<L {
            let i = y * L + x
            guard weights[i] > 0 else { continue }
            var dmin = r + 1
            outer: for d in 1...r {
                for dy in -d...d { for dx in -d...d where abs(dx) == d || abs(dy) == d {
                    let xx = x + dx, yy = y + dy
                    if xx < 0 || yy < 0 || xx >= L || yy >= L || weights[yy * L + xx] <= 0 { dmin = d; break outer }
                } }
            }
            out[i] = min(1, Float(dmin) / max(1e-3, radius))
        } }
        return out
    }

    @inline(__always)
    static func featherAt(_ mask: [Float], size L: Int, u: Float, v: Float) -> Float {
        let fx = min(Float(L) - 1, max(0, u * Float(L) - 0.5)), fy = min(Float(L) - 1, max(0, (1 - v) * Float(L) - 0.5))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(L - 1, x0 + 1), y1 = min(L - 1, y0 + 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = mask[y0 * L + x0] * (1 - tx) + mask[y0 * L + x1] * tx
        let bot = mask[y1 * L + x0] * (1 - tx) + mask[y1 * L + x1] * tx
        return top * (1 - ty) + bot * ty
    }
}
