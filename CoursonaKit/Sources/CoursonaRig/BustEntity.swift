//
//  BustEntity.swift
//  CoursonaRig
//
//  템플릿(+Identity) → 자체 정점 포맷의 `LowLevelMesh` → 매 프레임 52 셰이프 블렌딩 (T-006 스파이크, T-501/T-502).
//  경로 두 가지 (자동 선택, `pathDescription` 으로 UI 표시):
//   • GPU: `LowLevelDeformation`(RealityKit 27, OS 27+) — 블렌딩 스테이지(targetCount 52) 를 `encode(into:)` 로 매 프레임 인코딩.
//   • CPU: `LowLevelMesh.withUnsafeMutableBytes` 로 위치 = 기준 + Σ w·Δ (0 이 아닌 셰이프만). 법선은 레스트 법선 유지.
//  버퍼 배치: 0 = 위치(float3, 12B) · 1 = 법선(float3, 12B) · 2 = UV(float2). 블렌드 오프셋 버퍼 = targetCount × V × float3.
//  스키닝(목·머리·눈 뼈)은 M5(T-501) — 지금은 Head 뼈 회전을 엔티티 트랜스폼으로 근사한다.
//
//  입체감 v3(2026-10-07): 얼굴면 밖(두피·목·어깨)을 더는 별도 "고스트" 머티리얼 + 가우시안 스플랫 엔티티로
//  겹쳐 보여주지 않는다 — 실기기 점검에서 "흉상 메시(고스트)+스플랫 점구름+눈알/입안" 세 겹이 따로 보이는 문제로
//  확인됐다(사용자 스크린샷, 2026-10-06). 대신 얼굴면과 **같은 머티리얼 슬롯(0)** 을 "나머지" 파트에도 그대로
//  쓴다 — `PersonaBuildPipeline` 이 이제 `TextureBuilder` 를 `faceOnly` 없이 돌려 두피·목·어깨까지 같은 사진
//  투영+채움 기술로 한 장의 텍스처에 칠해 두므로(이미 있던 기능 — Chosang 시절부터의 전신 투영 경로를 되살린 것),
//  이 메시는 "하나의 엔티티, 하나의 기술"로 머리부터 어깨까지 보인다. 눈·입 캡은 여전히 별도 머티리얼(매끈함 차이)
//  이고, `EyesMouth.usdz` 를 붙이면 그 캡만 투명해진다(`attachEyesMouth`/`setCapsHidden`) — 그대로 둔다.
//  `SplatBinder`/`PhotoSplatBuilder`/`SplatGPUBridge`(`CoursonaSplat` 모듈)는 완전히 쓸모가 없어져 실제로
//  지웠다(`PersonaBuildPipeline.swift` 머리말 참고) — 되살릴 일이 있으면 git 이력에서 찾으면 된다.
//

import Foundation
import RealityKit
import Metal
import simd
import CoursonaCore
import CoursonaFace

public enum DeformationPath: String, Sendable { case gpuLowLevelDeformation = "LowLevelDeformation (GPU)", cpuBlend = "CPU 블렌드 (폴백)" }

@MainActor
public final class BustEntity {
    public let root: Entity
    public let model: ModelEntity
    public private(set) var template: BustTemplate
    public private(set) var identity: Identity
    public private(set) var path: DeformationPath
    public private(set) var lastUpdateMilliseconds: Double = 0
    public private(set) var updateCount = 0
    public var pathDescription: String { path.rawValue }

    let mesh: LowLevelMesh
    public let renderMesh: BustTemplate.RenderMesh
    let vertexCount: Int
    let basePositions: [SIMD3<Float>]
    let baseNormals: [SIMD3<Float>]
    /// 셰이프 순서 (targetCount 와 동일 순서)
    let shapeOrder: [ArkitShape]
    let deltas: [[SIMD3<Float>]]
    var lastWeights = ArkitWeights()
    /// `GPUBlendEngine`(OS 27+) — 배포 타깃이 26 이라 타입을 지울 수밖에 없다.
    private var gpu: AnyObject?
    /// 얼굴면/나머지 파트 경계(T-101) — 입체감 v3부터는 "나머지"도 같은 머티리얼(0)을 쓰므로 경계는 UV·채움 로직에만 쓰인다.
    public let faceSurface: FaceSurfacePartition
    /// 눈·입 구멍을 닫은 결과(T-102, C1 은 템플릿 좌표 v0 — C2 F5/F6 이 피팅 좌표로 다시 닫는다).
    public let capClosure: CapBuildResult
    /// 눈 캡 전용 머티리얼 인덱스(T-604, 있을 때만) — `applyGaze` 가 UV 오프셋을 넣을 자리.
    var eyeCapMaterialIndexLeft: Int?
    var eyeCapMaterialIndexRight: Int?
    var mouthCapMaterialIndex: Int?
    /// 시선 UV 오프셋 한계(§6.7 — 홍채 반지름의 절반 근처).
    private let eyeGazeMaxUVOffset: Float = 0.08

    // 입체감 v2(2026-10-06): `EyesMouth.usdz`(눈알 2 + 치아·잇몸·혀·입안) 를 붙였을 때의 상태 — `attachEyesMouth` 참고.
    /// 눈알 피벗(회전 중심 = 피팅된 눈 중심). 있으면 `applyGaze` 가 캡 UV 대신 이걸 돌린다.
    var eyePivotL: Entity?
    var eyePivotR: Entity?
    /// 입안(`Mouth_Inner`) 모델 — `update(weights:)` 가 jawOpen 등 5개 셰이프를 `BlendShapeWeightsComponent` 로 넘긴다.
    var mouthInner: ModelEntity?
    /// `attachEyesMouth`(EyesMouth.usdz) 또는 `attachPersonaAssets`(Template.usdz, D 절)가 눈/입을 붙였는가.
    public internal(set) var hasEyesMouth = false
    /// 시선 최대 회전(rad) — TechPRD "눈 뼈 look-at 최대 ±25°" 보다 조금 보수적으로.
    private let eyeGazeMaxRadians: Float = 0.35
    /// 템플릿(레스트) 입 루프 중심 — `Mouth_Inner` 를 피팅된 입 위치로 옮길 때의 기준(init 에서 rawTemplate 로 계산).
    let restMouthCenter: SIMD3<Float>
    let fittedMouthCenter: SIMD3<Float>
    /// 템플릿 레스트 정점(캡 추가 전, 원본 정점 수) — `template.positions` 는 피팅 좌표라, 에셋을 "레스트 → 피팅" 으로 옮길
    /// 변환(`PersonaAssets`: 두피 유사변환·어깨 축별 스케일)을 구할 때 이 레스트 좌표가 필요하다.
    let restPositions: [SIMD3<Float>]
    /// 캡 가시성(`setCapsHidden`·입 캡 폴백) — `flippedCapTriangles` 가 안 보이는 캡은 세지 않도록.
    private(set) var eyeCapsHidden = false
    private(set) var mouthCapHidden = false
    /// 셔츠 머티리얼 두 벌(하단 페이드 on/off) — 유령 룩 토글에 따라 `applyClothFade` 가 바꿔 끼운다(`PersonaAssets`).
    var clothFadeSwap: [(entity: Entity, faded: [Material], solid: [Material])] = []

    // 유령 룩(디자인 PRD 룩·렌더링 원칙, Tasks.md D-308 ③): 피부 머티리얼(0)의 PBR 원본을 보관해 셰이더 ↔ PBR 을 오간다.
    private var skinPBR: PhysicallyBasedMaterial?
    public private(set) var ghostLookOn = false
    private var ghostParams: (fresnel: Float, baseOpacity: Float, fadeHeight: Float) = (0.6, 0.85, 0.08)

    public init(template rawTemplate: BustTemplate, identity: Identity? = nil, material: Material? = nil, preferGPU: Bool = true, enableFaceCaps: Bool = true) throws {
        var id = identity ?? Identity.fromTemplate(rawTemplate)
        // F5·F6(v1, C2): Identity 가 진짜 피팅 결과면(정점 수가 원본 템플릿과 같다) 그 좌표로 눈·입 구멍을 닫는다 —
        // 캡은 항상 "지금 얼굴 모양" 기준이라 템플릿 좌표(v0)와 피팅 좌표(v1)가 같은 함수를 그대로 쓴다.
        var fittedTemplate = rawTemplate
        if id.positions.count == rawTemplate.vertexCount { fittedTemplate.positions = id.positions }
        // T-102: 눈·입 구멍을 닫는다. 구멍이 없는 템플릿(합성 등)은 조용히 건너뛴다.
        let capped = enableFaceCaps ? CapBuilder.addingCaps(to: fittedTemplate) : CapBuildResult(template: fittedTemplate, eyeLeft: nil, eyeRight: nil, mouth: nil, addedVertexIDs: [])
        let template = capped.template
        self.template = template
        self.capClosure = capped
        // 입 루프(패치 경계 36점) 중심 — 템플릿 좌표와 피팅 좌표 각각. 루프 정보가 없으면 manifest.mouthCenter/0.
        do {
            let loop = rawTemplate.manifest.patchLoops["mouth"] ?? []
            func centroid(_ ps: [SIMD3<Float>]) -> SIMD3<Float>? {
                let ids = loop.filter { $0 >= 0 && $0 < ps.count }
                guard !ids.isEmpty else { return nil }
                return ids.reduce(SIMD3<Float>.zero) { $0 + ps[$1] } / Float(ids.count)
            }
            let fallback = rawTemplate.manifest.mouthCenter.flatMap { $0.count == 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil } ?? .zero
            restMouthCenter = centroid(rawTemplate.positions) ?? fallback
            fittedMouthCenter = centroid(fittedTemplate.positions) ?? restMouthCenter
        }
        restPositions = rawTemplate.positions
        if id.positions.count != template.vertexCount {
            // 캡 이전(또는 다른 템플릿 버전) Identity 를 받으면 늘어난 만큼(캡이 새로 만든 정점) 채운다.
            if id.positions.count < template.vertexCount {
                id.positions += Array(template.positions[id.positions.count...])
            } else {
                id.positions = Array(id.positions.prefix(template.vertexCount))
            }
        }
        self.identity = id

        // T-101: 얼굴면(패치+띠+캡)이 앞쪽에 오도록 인덱스를 재배열. T-604: 캡별 구간도 같이 받아서
        // 눈·입 캡을 얼굴 피부와 다른 머티리얼(파트)로 떼어낼 수 있게 한다.
        let capIndexRanges = capped.caps.map(\.triangleIndexRange)
        let partition = FaceSurfacePartitioner.partition(template: template, additionalFaceVertexIDs: capped.addedVertexIDs, capIndexRanges: capIndexRanges)
        self.faceSurface = partition
        var partitionedTemplate = template
        partitionedTemplate.indices = partition.indices
        partitionedTemplate.cornerUVs = partition.cornerUVs

        // 렌더 메시 = 솔기에서 정점을 분할한 것 (UV 가 코너마다 다르므로). 원본 정점 → sourceIndex.
        let render = partitionedTemplate.makeRenderMesh()
        renderMesh = render
        vertexCount = render.vertexCount
        let srcPositions = id.positions.count == template.vertexCount ? id.positions : template.positions
        basePositions = render.expand(srcPositions)
        baseNormals = Geometry.vertexNormals(positions: basePositions, indices: render.indices)
        let runtime = id.runtimeDeltas(template: template)
        shapeOrder = ArkitShape.allCases.filter { runtime[$0] != nil }
        deltas = shapeOrder.map { render.expand(runtime[$0]!) }

        var desc = LowLevelMesh.Descriptor()
        desc.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 1, offset: 0),
            .init(semantic: .uv0, format: .float2, layoutIndex: 2, offset: 0),
        ]
        desc.vertexLayouts = [
            .init(bufferIndex: 0, bufferStride: 12),
            .init(bufferIndex: 1, bufferStride: 12),
            .init(bufferIndex: 2, bufferStride: 8),
        ]
        desc.vertexCapacity = vertexCount
        desc.indexCapacity = render.indices.count
        desc.indexType = .uint32
        let llm = try LowLevelMesh(descriptor: desc)
        mesh = llm
        let vc = render.vertexCount, uvs = render.uvs, indices = render.indices
        let positionsLocal = basePositions, normalsLocal = baseNormals
        Self.fill(llm, bufferIndex: 0, with: positionsLocal)
        Self.fill(llm, bufferIndex: 1, with: normalsLocal)
        llm.withUnsafeMutableBytes(bufferIndex: 2) { raw in
            let p = raw.bindMemory(to: SIMD2<Float>.self)
            for i in 0..<vc { p[i] = i < uvs.count ? uvs[i] : .zero }
        }
        llm.withUnsafeMutableIndices { raw in
            let p = raw.bindMemory(to: UInt32.self)
            for (i, v) in indices.enumerated() { p[i] = v }
        }
        func bounds(of range: Range<Int>) -> BoundingBox {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var seen = false
            for k in range {
                let v = Int(indices[k])
                lo = simd_min(lo, positionsLocal[v]); hi = simd_max(hi, positionsLocal[v]); seen = true
            }
            if !seen { lo = .zero; hi = .zero }
            // 표정으로 늘어나는 여유
            return BoundingBox(min: lo - SIMD3(repeating: 0.03), max: hi + SIMD3(repeating: 0.03))
        }
        let faceIndexCount = partition.faceIndexCount, restIndexCount = partition.restIndexCount
        var skin: Material = material ?? {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: .init(red: 0.86, green: 0.68, blue: 0.58, alpha: 1))
            m.roughness = .init(floatLiteral: 0.55)
            m.metallic = .init(floatLiteral: 0)
            return m
        }()
        if var pbr = skin as? PhysicallyBasedMaterial { pbr.faceCulling = .back; skin = pbr }

        // T-604: 얼굴 피부(0) 다음에, 있는 캡만(눈 왼쪽·오른쪽·입 순서 — `partition.capRanges` 와 같은 순서)
        // 전용 머티리얼·파트로 떼어낸다. 캡 UV 자체는 바뀌지 않고(텍스처는 TextureBuilder 가 그대로 투영),
        // 눈은 더 매끈하게(clearcoat)·입은 조금 덜 매끈하게 — §6.7.
        func capMaterial(roughnessValue: Float, clearcoatValue: Float) -> Material {
            var m: Material = skin
            if var pbr = m as? PhysicallyBasedMaterial {
                pbr.roughness = .init(floatLiteral: roughnessValue)
                pbr.clearcoat = .init(floatLiteral: clearcoatValue)
                pbr.faceCulling = .back
                m = pbr
            }
            return m
        }
        var materials: [Material] = [skin]
        var parts: [LowLevelMesh.Part] = []
        let totalCapIndexCount = partition.capRanges.reduce(0) { $0 + $1.count }
        let nonCapFaceCount = faceIndexCount - totalCapIndexCount
        parts.append(LowLevelMesh.Part(indexOffset: 0, indexCount: nonCapFaceCount, topology: .triangle, materialIndex: 0,
                                       bounds: bounds(of: 0..<nonCapFaceCount)))
        var capRangeIdx = 0
        if capped.eyeLeft != nil {
            let r = partition.capRanges[capRangeIdx]; capRangeIdx += 1
            materials.append(capMaterial(roughnessValue: 0.15, clearcoatValue: 0.6))
            eyeCapMaterialIndexLeft = materials.count - 1
            parts.append(LowLevelMesh.Part(indexOffset: r.lowerBound * MemoryLayout<UInt32>.size, indexCount: r.count, topology: .triangle,
                                           materialIndex: materials.count - 1, bounds: bounds(of: r)))
        }
        if capped.eyeRight != nil {
            let r = partition.capRanges[capRangeIdx]; capRangeIdx += 1
            materials.append(capMaterial(roughnessValue: 0.15, clearcoatValue: 0.6))
            eyeCapMaterialIndexRight = materials.count - 1
            parts.append(LowLevelMesh.Part(indexOffset: r.lowerBound * MemoryLayout<UInt32>.size, indexCount: r.count, topology: .triangle,
                                           materialIndex: materials.count - 1, bounds: bounds(of: r)))
        }
        if capped.mouth != nil {
            let r = partition.capRanges[capRangeIdx]; capRangeIdx += 1
            materials.append(capMaterial(roughnessValue: 0.7, clearcoatValue: 0))
            mouthCapMaterialIndex = materials.count - 1
            parts.append(LowLevelMesh.Part(indexOffset: r.lowerBound * MemoryLayout<UInt32>.size, indexCount: r.count, topology: .triangle,
                                           materialIndex: materials.count - 1, bounds: bounds(of: r)))
        }
        // 얼굴면 밖(두피·목·어깨): 입체감 v3부터는 "고스트"로 따로 가리지 않고 얼굴면과 **같은 머티리얼(0)** 을
        // 그대로 쓴다 — `PersonaBuildPipeline` 이 만든 한 장의 텍스처가 이 영역까지 사진 투영+채움으로 칠해 두므로,
        // 별도 머티리얼·별도 엔티티(스플랫) 없이 이 파트만으로 "얼굴면 기술의 확장"이 완성된다.
        parts.append(LowLevelMesh.Part(indexOffset: faceIndexCount * MemoryLayout<UInt32>.size, indexCount: restIndexCount, topology: .triangle,
                                       materialIndex: 0, bounds: bounds(of: faceIndexCount..<(faceIndexCount + restIndexCount))))
        llm.parts.replaceAll(parts)

        let resource = try MeshResource(from: llm)
        model = ModelEntity(mesh: resource, materials: materials)
        model.name = "Bust"
        root = Entity()
        root.name = "BustRoot"
        root.addChild(model)

        path = .cpuBlend
        #if !targetEnvironment(simulator)
        // LowLevelDeformation 은 기기·macOS SDK 에만 있다(xrsimulator/iphonesimulator 27.0 SDK 에는 심볼 없음 — T-006 측정). 시뮬레이터는 CPU 폴백.
        if preferGPU, !deltas.isEmpty {
            if #available(visionOS 27, iOS 27, macOS 27, *) {
                if let device = MTLCreateSystemDefaultDevice(),
                   let engine = try? GPUBlendEngine(device: device, vertexCount: vertexCount, basePositions: basePositions, baseNormals: baseNormals, deltas: deltas) {
                    gpu = engine
                    path = .gpuLowLevelDeformation
                }
            }
        }
        #endif
    }

    /// 이 빌드에서 GPU 경로를 쓸 수 있는가 (컴파일 타임: 시뮬레이터 SDK 에는 LowLevelDeformation 이 없다).
    public static var isGPUPathCompiled: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    static func fill(_ mesh: LowLevelMesh, bufferIndex: Int, with values: [SIMD3<Float>]) {
        mesh.withUnsafeMutableBytes(bufferIndex: bufferIndex) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            for (i, v) in values.enumerated() { p[i * 3] = v.x; p[i * 3 + 1] = v.y; p[i * 3 + 2] = v.z }
        }
    }

    /// 매 프레임: 52 가중치 적용. 변화가 없으면 건너뛴다.
    public func update(weights: ArkitWeights) {
        guard weights != lastWeights || updateCount == 0 else { return }
        lastWeights = weights
        let t0 = DispatchTime.now().uptimeNanoseconds
        switch path {
        case .gpuLowLevelDeformation:
            #if !targetEnvironment(simulator)
            if #available(visionOS 27, iOS 27, macOS 27, *), let gpu = gpu as? GPUBlendEngine {
                do { try gpu.encode(weights: shapeOrder.map { weights[$0] }, into: mesh) }
                catch {
                    path = .cpuBlend
                    cpuUpdate(weights)
                }
            } else { cpuUpdate(weights) }
            #else
            cpuUpdate(weights)
            #endif
        case .cpuBlend:
            cpuUpdate(weights)
        }
        lastUpdateMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        updateCount += 1
        updateMouthInner(weights)
        updateMouthCapFallbackVisibility(jawOpen: weights[.jawOpen])
    }

    /// 입 캡(`CapBuilder`가 만든 마개)은 `jawOpen` 셰이프에서 "테두리는 제 델타로, 캡 안쪽은 전부 테두리 평균
    /// 델타로" 보간(`CapBuilder.swift`) 때문에 입을 크게 벌리면 부채꼴이 뒤집히며 자기교차한다 — 뒤집힌 삼각형은
    /// `faceCulling = .back` 때문에 번갈아 안 보여 이빨처럼 보인다(실기기 재현, 2026-10-07, `FaceEntity`/얼굴면만
    /// 버전에서 먼저 확인). `mouthInner`(진짜 치아 메시)가 붙어 있으면 `setCapsHidden(mouth: true)` 가 이미 캡을
    /// 영구히 숨겨 뒀으니 이 폴백은 손대지 않는다 — `EyesMouth.usdz` 가 제대로 된 치아를 붙여 주지 못할 때만
    /// (오늘 기준 항상 그렇다 — `attachEyesMouth` 머리말의 "Eye_L/Mouth_Inner 는 지오메트리 없는 조인트" 참고)
    /// 입을 벌리면 캡을 통째로 숨겨 "입 안에 아무것도 없어" 보이게 한다.
    private func updateMouthCapFallbackVisibility(jawOpen: Float) {
        guard mouthInner == nil, let i = mouthCapMaterialIndex, var mc = model.components[ModelComponent.self],
              i < mc.materials.count, var pbr = mc.materials[i] as? PhysicallyBasedMaterial else { return }
        pbr.blending = jawOpen > 0.05 ? .transparent(opacity: .init(floatLiteral: 0)) : .opaque
        mc.materials[i] = pbr
        model.components[ModelComponent.self] = mc
    }

    // MARK: 눈알·입안 엔티티 (EyesMouth.usdz, 입체감 v2)

    /// `EyesMouth.usdz`(`TemplateStore.eyesMouthURL` → `Entity(contentsOf:)`) 를 붙인다.
    /// - 눈알(`Eye_L`/`Eye_R`): **피팅된 눈 중심**(`identity.eyeCenterL/R`, 눈꺼풀 링 구 피팅)에 피벗을 두고, 반지름 비
    ///   (`identity.eyeRadius / template.eyeRadius`)로 키운다. USDZ 눈알은 템플릿 눈 중심(`manifest.eyeL/R`)에 모델링돼
    ///   있으니 피벗 아래에서 그만큼 되돌려 놓는다 — 그러면 피벗 회전이 곧 눈알 회전(시선)이다.
    /// - 입안(`Mouth_Inner`): 템플릿 입 루프 중심 → 피팅 입 루프 중심으로 옮기고 머리 스케일(`identity.scale`)로 맞춘다.
    ///   `jawOpen` 등은 `update(weights:)` 가 `BlendShapeWeightsComponent` 로 넘긴다(Chosang 과 같은 경로).
    /// - 눈·입 캡은 완전 투명으로 — 구멍은 눈알/입안이 채우고, 테두리는 LidInner/LipInner 띠가 가린다.
    /// 전부 `model` 의 자식이라 머리 포즈·숨쉬기를 같이 따라간다.
    public func attachEyesMouth(_ loaded: Entity) {
        guard !hasEyesMouth else { return }
        let m = template.manifest
        let restEyeL = SIMD3<Float>(m.eyeL[0], m.eyeL[1], m.eyeL[2]), restEyeR = SIMD3<Float>(m.eyeR[0], m.eyeR[1], m.eyeR[2])
        let r0 = max(1e-4, m.eyeRadius)
        let eyeScale = max(0.5, min(2.0, identity.eyeRadius / r0))

        var eyeL: Entity?, eyeR: Entity?, mouth: ModelEntity?
        loaded.forEachDescendant { e in
            guard e.components[ModelComponent.self] != nil else { return }
            let n = e.name
            if n == "Eye_L" || n.hasSuffix("_Eye_L") || n.contains("Eye_L") { eyeL = eyeL ?? e }
            else if n == "Eye_R" || n.hasSuffix("_Eye_R") || n.contains("Eye_R") { eyeR = eyeR ?? e }
            else if n.contains("Mouth_Inner"), let me = e as? ModelEntity { mouth = mouth ?? me }
        }

        /// `e` 를 `loaded` 기준 누적 변환(USD 계층의 upAxis·아마추어 변환 포함)을 보존한 채 새 피벗 아래로 옮긴다.
        func reparent(_ e: Entity, under pivot: Entity, restCenter: SIMD3<Float>) {
            let toRoot = e.transformMatrix(relativeTo: loaded)
            var back = matrix_identity_float4x4
            back.columns.3 = SIMD4(-restCenter.x, -restCenter.y, -restCenter.z, 1)
            e.removeFromParent()
            pivot.addChild(e)
            e.transform = Transform(matrix: back * toRoot)
        }
        if let eyeL {
            let p = Entity(); p.name = "EyePivot_L"
            p.position = identity.eyeCenterL; p.scale = SIMD3(repeating: eyeScale)
            model.addChild(p); reparent(eyeL, under: p, restCenter: restEyeL); eyePivotL = p
        }
        if let eyeR {
            let p = Entity(); p.name = "EyePivot_R"
            p.position = identity.eyeCenterR; p.scale = SIMD3(repeating: eyeScale)
            model.addChild(p); reparent(eyeR, under: p, restCenter: restEyeR); eyePivotR = p
        }
        if let mouth {
            let p = Entity(); p.name = "MouthInnerPivot"
            p.position = fittedMouthCenter; p.scale = SIMD3(repeating: max(0.6, min(1.6, identity.scale)))
            model.addChild(p); reparent(mouth, under: p, restCenter: restMouthCenter)
            let comp = BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: mouth.model?.mesh ?? MeshResource.generateBox(size: 0.001)))
            if comp.weightSet.contains(where: { !$0.weightNames.isEmpty }) { mouth.components.set(comp) }
            mouthInner = mouth
        }
        // 남은 것(아마추어 등 빈 엔티티)은 그대로 모델 아래에 — 보이지 않는다.
        model.addChild(loaded)

        guard eyePivotL != nil || eyePivotR != nil || mouthInner != nil else { return }
        hasEyesMouth = true
        setCapsHidden(eyes: eyePivotL != nil || eyePivotR != nil, mouth: mouthInner != nil)
        updateMouthInner(lastWeights)
    }

    // MARK: 피부 머티리얼 · 유령 룩 (D-308)

    /// 사진 알베도를 피부 머티리얼(0)에 올린다. 유령 룩이 켜져 있으면 셰이더 머티리얼로 다시 감싼다 — 호출 순서와 무관하게
    /// 텍스처와 룩이 둘 다 남는다(이전엔 InspectionView 가 PBR 을 통째로 갈아끼워 셰이더가 사라질 수 있었다).
    public func setSkinTexture(_ texture: TextureResource) {
        var pbr = skinPBR ?? (model.components[ModelComponent.self]?.materials.first as? PhysicallyBasedMaterial) ?? PhysicallyBasedMaterial()
        // 틴트는 명시적으로 흰색 — 초기 피부 머티리얼의 살구색 틴트가 남으면 커스텀 셰이더의 base_color_tint() 에 그대로 나온다.
        pbr.baseColor = .init(tint: .white, texture: .init(texture))
        pbr.roughness = .init(floatLiteral: 0.55)
        pbr.metallic = .init(floatLiteral: 0)
        pbr.faceCulling = .back
        skinPBR = pbr
        refreshSkinMaterial()
    }

    /// 유령 룩: 피부를 기본 불투명도 `baseOpacity` × (1 − fresnel·edge²) × 하단 `fadeHeight`(m) 페이드로 그린다
    /// (`coursonaPersonaBust` 셰이더). 셰이더가 없는 환경(패키지 테스트·옛 metallib)이면 false — PBR 그대로.
    @discardableResult
    public func setGhostLook(_ on: Bool, fresnel: Float = 0.6, baseOpacity: Float = 0.85, fadeHeight: Float = 0.08) -> Bool {
        if on { guard PersonaSurfaceShader.shared?.bustSurfaceShader != nil else { ghostLookOn = false; return false } }
        ghostParams = (fresnel, baseOpacity, fadeHeight)
        ghostLookOn = on
        if skinPBR == nil { skinPBR = model.components[ModelComponent.self]?.materials.first as? PhysicallyBasedMaterial }
        refreshSkinMaterial()
        applyClothFade(ghost: on)
        return true
    }

    private func refreshSkinMaterial() {
        guard var mc = model.components[ModelComponent.self], !mc.materials.isEmpty, let pbr = skinPBR else { return }
        var mat: Material = pbr
        if ghostLookOn, let shader = PersonaSurfaceShader.shared {
            // 하단 페이드는 모델 좌표 y 의 바닥(어깨 절단면)에서 fadeHeight 만큼 — LowLevelMesh 좌표는 템플릿 좌표 그대로다.
            let yMin = basePositions.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
            if let cm = shader.makeBustMaterial(from: pbr, fresnel: ghostParams.fresnel, fadeY: SIMD2(yMin, yMin + ghostParams.fadeHeight),
                                                baseOpacity: ghostParams.baseOpacity) { mat = cm }
        }
        mc.materials[0] = mat
        model.components[ModelComponent.self] = mc
    }

    /// 눈·입 캡 머티리얼을 완전 투명으로(또는 되돌림). 캡 지오메트리는 남겨 두어 파트 순서·고스트 슬롯이 그대로다.
    func setCapsHidden(eyes: Bool, mouth: Bool) {
        guard var mc = model.components[ModelComponent.self] else { return }
        func hide(_ i: Int?) {
            guard let i, i < mc.materials.count, var pbr = mc.materials[i] as? PhysicallyBasedMaterial else { return }
            pbr.blending = .transparent(opacity: .init(floatLiteral: 0))
            mc.materials[i] = pbr
        }
        if eyes { hide(eyeCapMaterialIndexLeft); hide(eyeCapMaterialIndexRight); eyeCapsHidden = true }
        if mouth { hide(mouthCapMaterialIndex); mouthCapHidden = true }
        model.components[ModelComponent.self] = mc
    }

    /// 지금 **보이는** 캡 삼각형 중 주어진 가중치에서 뒤집히는(법선이 레스트와 반대) 수 — `SelfIntersectionCheck` 와 같은
    /// 근사를 실제 렌더 정점·실제 런타임 델타(Identity 보정 반영)로, 그리고 지금 포즈 하나에 대해 센다.
    /// 눈·입 에셋이 붙어 투명해진 캡, 입 벌림 폴백으로 숨긴 입 캡은 어차피 안 보이니 제외한다(`includeHidden` 으로 포함 가능).
    /// 검수 화면의 "겹침" 배지용(2026-10-08): 이전엔 52 셰이프 각각 1.0 의 합(템플릿 자체가 ≈250)을 포즈와 무관하게 보여줘
    /// 포즈를 바꿔도 숫자가 안 변하고, 보이지도 않는 캡을 "겹침 의심"으로 세고 있었다.
    public func flippedCapTriangles(weights: ArkitWeights, includeHidden: Bool = false) -> Int {
        var active: [(Float, [SIMD3<Float>])] = []
        for (k, s) in shapeOrder.enumerated() { let w = weights[s]; if w > 0.001 { active.append((w, deltas[k])) } }
        guard !active.isEmpty else { return 0 }
        let idx = renderMesh.indices
        func posed(_ v: Int) -> SIMD3<Float> { var p = basePositions[v]; for (w, d) in active where v < d.count { p += d[v] * w }; return p }
        // `faceSurface.capRanges` 순서 = 눈 왼쪽·눈 오른쪽·입 중 있는 것(init 의 파트 순서와 동일).
        var kinds: [Bool] = []   // true = 눈 캡, false = 입 캡
        if capClosure.eyeLeft != nil { kinds.append(true) }
        if capClosure.eyeRight != nil { kinds.append(true) }
        if capClosure.mouth != nil { kinds.append(false) }
        var flipped = 0
        for (ci, r) in faceSurface.capRanges.enumerated() {
            if !includeHidden, ci < kinds.count {
                let isEye = kinds[ci]
                if isEye && eyeCapsHidden { continue }
                if !isEye && (mouthCapHidden || (mouthInner == nil && weights[.jawOpen] > 0.05)) { continue }
            }
            var k = r.lowerBound
            while k + 2 < r.upperBound, k + 2 < idx.count {
                let a = Int(idx[k]), b = Int(idx[k + 1]), c = Int(idx[k + 2])
                let nRest = simd_cross(basePositions[b] - basePositions[a], basePositions[c] - basePositions[a])
                let pa = posed(a), pb = posed(b), pc = posed(c)
                if simd_dot(nRest, simd_cross(pb - pa, pc - pa)) < 0 { flipped += 1 }
                k += 3
            }
        }
        return flipped
    }

    /// `Mouth_Inner` 의 5개 셰이프(jawOpen·jawLeft·jawRight·jawForward·tongueOut) — USD 가 중복 이름에 붙인 접미 숫자
    /// (`jawOpen2`) 를 떼고 같은 ARKit 가중치를 넣는다. 흉상의 jawOpen 과 같은 값이라 입술과 치아가 같이 움직인다.
    func updateMouthInner(_ weights: ArkitWeights) {
        guard let mouthInner, var comp = mouthInner.components[BlendShapeWeightsComponent.self] else { return }
        for i in comp.weightSet.indices {
            var data = comp.weightSet[i]
            for (j, full) in data.weightNames.enumerated() {
                let name = full.split(separator: "/").last.map(String.init) ?? full
                let base = String(name.reversed().drop(while: { $0.isNumber }).reversed())
                data.weights[j] = ArkitShape(rawValue: base).map { weights[$0] } ?? 0
            }
            comp.weightSet[i] = data
        }
        mouthInner.components.set(comp)
    }

    /// 홍채 색을 바꾼다(사진에서 추정한 색 — 안 부르면 USDZ 기본색). 눈알 USDZ 의 머티리얼 순서는 Blender 빌드
    /// (`uv_eyes_mouth.py`: 0 = 공막, 1 = 홍채, 2 = 동공 — 정면축 각도 9.5°/29° 로 가름)대로라, 슬롯 3개면 1번만 바꾼다.
    public func setIrisColor(_ rgb: SIMD3<Float>) {
        for pivot in [eyePivotL, eyePivotR].compactMap({ $0 }) {
            pivot.forEachDescendant { e in
                guard var mc = e.components[ModelComponent.self], mc.materials.count == 3,
                      var pbr = mc.materials[1] as? PhysicallyBasedMaterial else { return }
                pbr.baseColor = .init(tint: .init(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
                mc.materials[1] = pbr
                e.components[ModelComponent.self] = mc
            }
        }
    }

    /// 사진에서 홍채 색을 추정한다: 눈 캡(눈 구멍을 닫은 팬)의 중심 정점 UV 주변 알베도 텍셀 중 **어두운 절반**의 평균
    /// (공막은 밝고 홍채·동공은 어둡다). 캡 UV 섬은 `TextureBuilder` 가 사진을 그대로 투영한 자리라 실제 눈 색이 들어 있다.
    /// 텍셀 행은 `(1 - v)`(TextureBuilder 와 같은 규약). 캡이 없거나 샘플이 모자라면 nil.
    public func estimateIrisColor(from albedo: RGBAImage) -> SIMD3<Float>? {
        guard albedo.width > 8, albedo.height > 8 else { return nil }
        var samples: [SIMD3<Float>] = []
        for cap in [capClosure.eyeLeft, capClosure.eyeRight].compactMap({ $0 }) {
            guard let center = cap.addedVertexIDs.last, center < template.uvs.count else { continue }
            let uv = template.uvs[center]
            let cx = Int(uv.x * Float(albedo.width)), cy = Int((1 - uv.y) * Float(albedo.height))
            let r = max(2, albedo.width / 128)
            for dy in -r...r { for dx in -r...r where dx * dx + dy * dy <= r * r {
                let x = cx + dx, y = cy + dy
                guard x >= 0, y >= 0, x < albedo.width, y < albedo.height else { continue }
                let o = (y * albedo.width + x) * 4
                samples.append(SIMD3(Float(albedo.bytes[o]), Float(albedo.bytes[o + 1]), Float(albedo.bytes[o + 2])) / 255)
            } }
        }
        guard samples.count >= 8 else { return nil }
        samples.sort { ($0.x + $0.y + $0.z) < ($1.x + $1.y + $1.z) }
        let dark = samples.prefix(max(4, samples.count / 2))
        let mean = dark.reduce(SIMD3<Float>.zero, +) / Float(dark.count)
        // 너무 어두우면(동공만 잡힘) 조금 띄워 홍채답게.
        return simd_max(mean, SIMD3(repeating: 0.08))
    }

    /// 진단(2026-10-08, 눈 감기 때 눈알이 보이는 문제): 주어진 가중치로 CPU 에서 계산한 패치 정점과 **실제 눈알 피벗**(위치·스케일)의
    /// 구면 거리를 잰다 — 앱에 붙은 눈알 기준으로 눈꺼풀이 안/밖 어디에 있는지. 음수 = 눈알이 눈꺼풀 밖으로 나온다.
    public func debugEyeClosure(weights: ArkitWeights) -> String {
        var lines: [String] = []
        let r0 = template.manifest.eyeRadius
        for (name, pivot) in [("L", eyePivotL), ("R", eyePivotR)] {
            guard let pivot else { lines.append("\(name): 눈알 없음"); continue }
            let c = pivot.position, r = r0 * pivot.scale.x
            var minD = Float.greatestFiniteMagnitude, n = 0, inside = 0
            for v in 0..<min(template.patchCount, basePositions.count) {
                // 렌더 정점 → 원본 정점 매핑 없이, 원본 패치 정점 v 의 첫 렌더 정점을 쓴다
                guard let rv = renderMesh.sourceIndex.firstIndex(where: { Int($0) == v }) else { continue }
                var p = basePositions[rv]
                for (k, s) in shapeOrder.enumerated() { let w = weights[s]; if w > 0.001, rv < deltas[k].count { p += deltas[k][rv] * w } }
                let d = simd_length(p - c) - r
                guard simd_length(p - c) < r * 1.9 else { continue }
                n += 1; minD = min(minD, d); if d < 0 { inside += 1 }
            }
            lines.append(String(format: "%@: 피벗 (%.1f, %.1f, %.1f) r %.1f mm · 눈꺼풀 패치 %d점 · 구면 최소 %.1f mm · 안쪽 %d점", name as NSString, c.x * 1000, c.y * 1000, c.z * 1000, r * 1000, n, minD * 1000, inside))
        }
        return lines.joined(separator: " | ")
    }

    /// 눈알 깊이 보정(2026-10-08): 사진 피팅(희소)에서는 눈 둘레가 RBF 로 조금씩 움직여 눈꺼풀 닫힘 궤적과 눈알 구면이 어긋난다 —
    /// 실측 eyeBlink 1.0 에서 눈꺼풀 패치 정점 128점 중 49점이 구면 안(최소 −2.7/−4.1 mm) → 눈을 감아도 눈알이 뚫고 보였다.
    /// 초상 템플릿이 쓴 방법 그대로("구멍 정점 전부가 구면 바깥에 오도록 뒤로"): 눈을 감은 상태의 눈꺼풀 패치 정점이 모두
    /// 구면 + `margin` 바깥에 올 때까지 눈 중심을 뒤(−z)로 민다(최대 `maxShift`). 반환 = 뒤로 민 거리(m).
    public func eyeDepthCorrection(center c: SIMD3<Float>, radius r: Float, margin: Float = 0.0005, maxShift: Float = 0.006) -> Float {
        var w = ArkitWeights(); w[.eyeBlinkLeft] = 1; w[.eyeBlinkRight] = 1
        var firstRender = [Int: Int]()
        for (rv, s) in renderMesh.sourceIndex.enumerated() where firstRender[Int(s)] == nil { firstRender[Int(s)] = rv }
        var pts: [SIMD3<Float>] = []
        for v in 0..<min(template.patchCount, basePositions.count) {
            guard let rv = firstRender[v] else { continue }
            var p = basePositions[rv]
            guard simd_length(p - c) < r * 1.9 else { continue }
            for (k, s) in shapeOrder.enumerated() { let wk = w[s]; if wk > 0.001, rv < deltas[k].count { p += deltas[k][rv] * wk } }
            pts.append(p)
        }
        guard !pts.isEmpty else { return 0 }
        var shift: Float = 0
        while shift < maxShift {
            let cc = c - SIMD3(0, 0, shift)
            if pts.allSatisfy({ simd_length($0 - cc) >= r + margin }) { break }
            shift += 0.00025
        }
        return min(shift, maxShift)
    }

    /// 알베도의 두피(Scalp 그룹) 텍셀 평균으로 머리카락색을 추정한다 — 패키지 매니페스트에 `hairTint` 가 없는 옛 페르소나용 폴백.
    /// `TextureBuilder` 가 두피 영역을 사진 머리색으로 채워 두므로(관측 평균 또는 채움색) 그 평균이 곧 머리색이다. 0…1 sRGB.
    public func estimateHairColor(from albedo: RGBAImage) -> SIMD3<Float>? {
        guard albedo.width > 8, albedo.height > 8 else { return nil }
        let scalp = template.manifest.group(.scalp)
        guard !scalp.isEmpty else { return nil }
        var sum = SIMD3<Float>.zero, n = 0
        let step = max(1, scalp.count / 600)
        for (i, v) in scalp.enumerated() where i % step == 0 && v < template.uvs.count {
            let uv = template.uvs[v]
            let x = min(albedo.width - 1, max(0, Int(uv.x * Float(albedo.width))))
            let y = min(albedo.height - 1, max(0, Int((1 - uv.y) * Float(albedo.height))))
            let o = (y * albedo.width + x) * 4
            sum += SIMD3(Float(albedo.bytes[o]), Float(albedo.bytes[o + 1]), Float(albedo.bytes[o + 2])) / 255
            n += 1
        }
        guard n >= 16 else { return nil }
        return sum / Float(n)
    }

    /// Soban식 절차적 움직임 한 프레임: 머리 yaw/pitch/roll(rad, Head 피벗 기준) + 숨쉬기(Y 스케일, 가슴 기준) + 상하 bob.
    /// `applyHeadPose` 와 같은 `model.transform` 을 쓰므로 둘 중 하나만 매 프레임 부른다.
    public func applyIdleMotion(yaw: Float, pitch: Float, roll: Float, breathScale: Float, bob: Float) {
        let headPivot = SIMD3<Float>(0, 0.36, 0)
        let chestPivot = SIMD3<Float>(0, 0.22, 0)
        let q = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))
        // 회전은 머리 피벗 기준, 숨 스케일은 가슴 피벗 기준: T(h) R T(-h) 뒤에 T(c) S T(-c), 마지막에 bob.
        var rot = simd_float4x4(q)
        rot.columns.3 = SIMD4(headPivot - q.act(headPivot), 1)
        var sc = matrix_identity_float4x4
        sc.columns.1.y = breathScale
        sc.columns.3 = SIMD4(0, chestPivot.y - chestPivot.y * breathScale + bob, 0, 1)
        model.transform = Transform(matrix: sc * rot)
    }

    private func cpuUpdate(_ weights: ArkitWeights) {
        var active: [(Float, [SIMD3<Float>])] = []
        for (k, s) in shapeOrder.enumerated() { let w = weights[s]; if w > 0.001 { active.append((w, deltas[k])) } }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            for i in 0..<vertexCount {
                var v = basePositions[i]
                for (w, d) in active { v += d[i] * w }
                p[i * 3] = v.x; p[i * 3 + 1] = v.y; p[i * 3 + 2] = v.z
            }
        }
    }

    /// Head 뼈 포즈 근사: 루트 아래 모델 엔티티를 Head 피벗(0, 0.36, 0) 기준으로 회전 (스키닝은 M5).
    public func applyHeadPose(_ pose: BonePose?, neck: BonePose? = nil) {
        let pivot = SIMD3<Float>(0, 0.36, 0)
        var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        if let neck { q = neck.rotation * q }
        if let pose { q = q * pose.rotation }
        let pos = (pose?.position ?? .zero) + (neck?.position ?? .zero)
        model.transform = Transform(scale: .one, rotation: q, translation: pivot - q.act(pivot) + pos)
    }

    /// T-604: 시선을 눈 캡 머티리얼의 UV 오프셋으로 표현한다(기하는 그대로라 뚫림이 없다, §6.7).
    /// `gaze` 는 대략 -1...1(피사체 기준 오른쪽·아래가 양수) — 내부에서 ±0.08 UV 로 스케일한다.
    /// 눈 캡이 없는 템플릿(구멍 없는 합성 템플릿 등)에서는 조용히 아무 일도 하지 않는다.
    public func applyGaze(_ gaze: SIMD2<Float>) {
        let g = simd_clamp(gaze, SIMD2(repeating: -1), SIMD2(repeating: 1))
        // 입체감 v2: 진짜 눈알이 있으면 캡 UV 대신 눈알을 돌린다. 흉상 공간은 +X 가 피사체 왼쪽(eyeL.x > 0), 정면 +Z.
        // `FaceRigSystem.gazeFromWeights` 의 +g.x 는 eyeLookOutLeft+eyeLookInRight = **피사체 왼쪽**(+X) 을 보는 것이라
        // +Z 를 +X 쪽으로 → Y축 양(+) 회전(이전엔 음(−)이라 눈알이 눈꺼풀 델타와 반대쪽으로 돌았다, 2026-10-08 실기기 캡처 검수).
        // 아래(+g.y, eyeLookDown)를 보려면 +Z 를 −Y 쪽으로 → X축 양(+) 회전.
        if eyePivotL != nil || eyePivotR != nil {
            let q = simd_quatf(angle: g.x * eyeGazeMaxRadians, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: g.y * eyeGazeMaxRadians, axis: SIMD3(1, 0, 0))
            eyePivotL?.orientation = q
            eyePivotR?.orientation = q
            return
        }
        guard eyeCapMaterialIndexLeft != nil || eyeCapMaterialIndexRight != nil else { return }
        guard var mc = model.components[ModelComponent.self] else { return }
        let offset = simd_clamp(gaze, SIMD2(repeating: -1), SIMD2(repeating: 1)) * eyeGazeMaxUVOffset
        let transform = PhysicallyBasedMaterial.TextureCoordinateTransform(offset: offset, scale: SIMD2(repeating: 1), rotation: 0)
        if let i = eyeCapMaterialIndexLeft, var pbr = mc.materials[i] as? PhysicallyBasedMaterial { pbr.textureCoordinateTransform = transform; mc.materials[i] = pbr }
        if let i = eyeCapMaterialIndexRight, var pbr = mc.materials[i] as? PhysicallyBasedMaterial { pbr.textureCoordinateTransform = transform; mc.materials[i] = pbr }
        model.components[ModelComponent.self] = mc
    }

}

#if !targetEnvironment(simulator)
/// LowLevelDeformation 블렌딩 엔진 (OS 27+, 기기·macOS 전용 — 시뮬레이터 SDK 에 없음).
@available(visionOS 27, iOS 27, macOS 27, *)
@MainActor
final class GPUBlendEngine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: LowLevelDeformationContext
    let pipeline: LowLevelDeformation.Pipeline
    let deformation: LowLevelDeformation
    let inputPositions: MTLBuffer
    let inputNormals: MTLBuffer
    let offsets: MTLBuffer
    let weightsBuffer: MTLBuffer
    let vertexCount: Int
    let targetCount: Int

    init(device: MTLDevice, vertexCount: Int, basePositions: [SIMD3<Float>], baseNormals: [SIMD3<Float>], deltas: [[SIMD3<Float>]]) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw BustEntityError.metalUnavailable }
        queue = q
        self.vertexCount = vertexCount
        targetCount = deltas.count
        context = try LowLevelDeformationContext(device)

        // 위치만 블렌딩(법선 델타가 없으므로 blendsOutputs 비움). 법선 버퍼(1)는 LowLevelMesh 쪽에 그대로 둔다.
        // 스키닝·재정규화는 M5(T-501)에서 pd.skinning / pd.renormalization(outputs: [.normal]) 로 켠다.
        var pd = LowLevelDeformation.Pipeline.Descriptor()
        let posAttr = LowLevelDeformation.VertexAttribute(semantic: .position, format: .float3, stride: 12)
        pd.inputAttributes = [posAttr]
        pd.outputAttributes = [posAttr]
        pd.blendShape = LowLevelDeformation.Pipeline.Descriptor.BlendShape(blendsOutputs: [])
        pd.skinning = nil
        pd.renormalization = nil
        pipeline = try context.makePipeline(pd)
        let dd = LowLevelDeformation.Descriptor(vertexCount: vertexCount, blendShape: .init(targetCount: targetCount), skinning: nil, renormalization: nil)
        deformation = try context.makeDeformation(pipeline: pipeline, descriptor: dd)

        func packed(_ arr: [SIMD3<Float>]) -> [Float] { var f = [Float](); f.reserveCapacity(arr.count * 3); for v in arr { f.append(v.x); f.append(v.y); f.append(v.z) }; return f }
        let pos = packed(basePositions), nrm = packed(baseNormals)
        guard let ip = device.makeBuffer(bytes: pos, length: pos.count * 4, options: .storageModeShared),
              let inr = device.makeBuffer(bytes: nrm, length: nrm.count * 4, options: .storageModeShared),
              let off = device.makeBuffer(length: max(12, targetCount * vertexCount * 12), options: .storageModeShared),
              let wb = device.makeBuffer(length: max(4, targetCount * 4), options: .storageModeShared) else { throw BustEntityError.metalUnavailable }
        inputPositions = ip; inputNormals = inr; offsets = off; weightsBuffer = wb
        let op = off.contents().assumingMemoryBound(to: Float.self)
        for (t, d) in deltas.enumerated() {
            for i in 0..<vertexCount { let k = (t * vertexCount + i) * 3; op[k] = d[i].x; op[k + 1] = d[i].y; op[k + 2] = d[i].z }
        }
        try deformation.input.setVertices(inputPositions, offset: 0, semantic: .position)
        try deformation.blendShape.setPositionOffsets(offsets, offset: 0)
        try deformation.blendShape.setWeights(weightsBuffer, offset: 0)
    }

    func encode(weights: [Float], into mesh: LowLevelMesh) throws {
        let wp = weightsBuffer.contents().assumingMemoryBound(to: Float.self)
        for (i, w) in weights.enumerated() where i < targetCount { wp[i] = w }
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw BustEntityError.metalUnavailable }
        let outPos = mesh.replace(bufferIndex: 0, using: cb)
        try deformation.output.setVertices(outPos, offset: 0, semantic: .position)
        try deformation.encode(into: enc)
        enc.endEncoding()
        cb.commit()
    }
}
#endif

public enum BustEntityError: Error, LocalizedError {
    case metalUnavailable
    public var errorDescription: String? { "Metal 장치를 만들 수 없습니다" }
}
