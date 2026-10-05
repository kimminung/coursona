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
    /// 얼굴면/나머지 파트 경계(T-101) — 머티리얼 인덱스 0 = 얼굴면, 1 = 나머지.
    public let faceSurface: FaceSurfacePartition
    /// 눈·입 구멍을 닫은 결과(T-102, C1 은 템플릿 좌표 v0 — C2 F5/F6 이 피팅 좌표로 다시 닫는다).
    public let capClosure: CapBuildResult
    private var ghostMaterial: PhysicallyBasedMaterial
    /// 얼굴면 밖(머리·목·어깨)을 반투명 "고스트"로 보여줄지. 기본은 완전히 뺀다(TechPRD §3·§6.2 — "투명 = 파트 제외").
    public private(set) var isGhostVisible = false

    public init(template rawTemplate: BustTemplate, identity: Identity? = nil, material: Material? = nil, preferGPU: Bool = true, enableFaceCaps: Bool = true) throws {
        // T-102: 눈·입 구멍을 먼저 닫는다(템플릿 좌표 v0). 구멍이 없는 템플릿(합성 등)은 조용히 건너뛴다.
        let capped = enableFaceCaps ? CapBuilder.addingCaps(to: rawTemplate) : CapBuildResult(template: rawTemplate, eyeLeft: nil, eyeRight: nil, mouth: nil, addedVertexIDs: [])
        let template = capped.template
        self.template = template
        self.capClosure = capped
        var id = identity ?? Identity.fromTemplate(template)
        if id.positions.count != template.vertexCount {
            // 캡 이전(또는 다른 템플릿 버전) Identity 를 받으면 늘어난 만큼 템플릿 좌표로 채운다.
            // 피팅 결과가 캡까지 포함하게 만드는 건 C2(F6 v1)의 일이다.
            if id.positions.count < template.vertexCount {
                id.positions += Array(template.positions[id.positions.count...])
            } else {
                id.positions = Array(id.positions.prefix(template.vertexCount))
            }
        }
        self.identity = id

        // T-101: 얼굴면(패치+띠+캡)이 앞쪽에 오도록 인덱스를 재배열 — 렌더 파트 2개로 나뉘는 경계가 된다.
        let partition = FaceSurfacePartitioner.partition(template: template, additionalFaceVertexIDs: capped.addedVertexIDs)
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
        llm.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0, indexCount: faceIndexCount, topology: .triangle, materialIndex: 0,
                              bounds: bounds(of: 0..<faceIndexCount)),
            LowLevelMesh.Part(indexOffset: faceIndexCount * MemoryLayout<UInt32>.size, indexCount: restIndexCount, topology: .triangle, materialIndex: 1,
                              bounds: bounds(of: faceIndexCount..<(faceIndexCount + restIndexCount))),
        ])

        let resource = try MeshResource(from: llm)
        var skin: Material = material ?? {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: .init(red: 0.86, green: 0.68, blue: 0.58, alpha: 1))
            m.roughness = .init(floatLiteral: 0.55)
            m.metallic = .init(floatLiteral: 0)
            return m
        }()
        if var pbr = skin as? PhysicallyBasedMaterial { pbr.faceCulling = .back; skin = pbr }
        // 얼굴면 밖(머리·목·어깨): 기본은 완전히 뺀다(opacity 0) — "투명 = 파트 제외"(TechPRD §3).
        // `setGhostVisible(true)` 로 디버그·시뮬레이터 폴백용 옅은 고스트(0.15)를 켤 수 있다.
        var ghost = PhysicallyBasedMaterial()
        ghost.baseColor = .init(tint: .init(red: 0.6, green: 0.6, blue: 0.65, alpha: 1))
        ghost.roughness = .init(floatLiteral: 0.8)
        ghost.metallic = .init(floatLiteral: 0)
        ghost.blending = .transparent(opacity: .init(floatLiteral: 0))
        ghost.faceCulling = .back
        ghostMaterial = ghost
        model = ModelEntity(mesh: resource, materials: [skin, ghost])
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

    /// 얼굴면 밖(머리·목·어깨)을 옅은 고스트(opacity 0.15)로 보일지. 기본(false)은 완전히 뺀다(opacity 0).
    /// 디버그 토글이나 스플랫 미지원 폴백(시뮬레이터 등, C5)에서 켠다.
    public func setGhostVisible(_ visible: Bool) {
        guard isGhostVisible != visible else { return }
        isGhostVisible = visible
        ghostMaterial.blending = .transparent(opacity: .init(floatLiteral: visible ? 0.15 : 0))
        guard var mc = model.components[ModelComponent.self] else { return }
        mc.materials = [mc.materials.first ?? ghostMaterial, ghostMaterial]
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
