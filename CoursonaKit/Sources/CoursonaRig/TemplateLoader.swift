//
//  TemplateLoader.swift
//  CoursonaRig
//
//  USDZ → BustTemplate (T-004 스파이크 + T-104 로더). `Entity(contentsOf:)` 로 1회 로드 → `MeshResource.contents` 의
//  models[].parts[] 에서 정점·법선·UV·인덱스·`blendShapeOffsets(named:)`·jointInfluences·skeletons 를 읽는다.
//  셰이프 이름은 `BlendShapeWeightsMapping(meshResource:)` → `BlendShapeWeightsComponent.weightSet[].weightNames` 로 얻는다(소반 8차와 같은 경로).
//  보고서(`TemplateLoadReport`)가 "무엇이 읽혔는지" 를 남겨 Docs/Spikes.md 의 근거가 된다.
//

import Foundation
import RealityKit
import simd
import CoursonaCore

public struct TemplateLoadReport: Sendable {
    /// 모델 엔티티별 요약 (레거시 USDZ 처럼 메시가 여러 개일 때 어디에 셰이프가 있는지).
    public struct EntitySummary: Sendable {
        public var name: String
        public var vertexCount: Int
        public var shapeNames: [String]
        public var readableOffsets: Int
        public var hasJointInfluences: Bool
    }
    public var url: String
    public var entities: [EntitySummary] = []
    public var entityNames: [String] = []
    public var modelEntityCount = 0
    public var partCount = 0
    public var chosenEntity = ""
    public var vertexCount = 0
    public var triangleCount = 0
    public var hasNormals = false
    public var hasUVs = false
    public var blendShapeNames: [String] = []
    /// 이름 → blendShapeOffsets(named:) 가 nil 이 아니었고 길이가 정점 수와 같은지
    public var readableOffsets: [String: Bool] = [:]
    public var skeletonIDs: [String] = []
    public var jointNames: [String] = []
    public var jointInfluenceCount = 0
    public var influencesPerVertex = 0
    public var elapsed: Double = 0
    public var notes: [String] = []

    public var offsetsReadableCount: Int { readableOffsets.values.filter { $0 }.count }
    public var summary: String {
        var s = "\(url.split(separator: "/").last ?? "") — 엔티티 \(entityNames.count) · 모델 \(modelEntityCount) · 파트 \(partCount) · 선택 \(chosenEntity)\n"
        for e in entities where e.vertexCount > 0 {
            s += "  · \(e.name): 정점 \(e.vertexCount), 셰이프 \(e.shapeNames.count)개, 오프셋 읽힘 \(e.readableOffsets)개\(e.hasJointInfluences ? ", 스킨 O" : "")\n"
        }
        s += "정점 \(vertexCount) · 삼각형 \(triangleCount) · 법선 \(hasNormals ? "O" : "X") · UV \(hasUVs ? "O" : "X")\n"
        s += "셰이프키 \(blendShapeNames.count)개, blendShapeOffsets(named:) 읽힘 \(offsetsReadableCount)개\n"
        s += "스켈레톤 \(skeletonIDs.count) · 조인트 \(jointNames.count) · jointInfluences \(jointInfluenceCount) (정점당 \(influencesPerVertex))\n"
        s += String(format: "로드 %.2f s", elapsed)
        if !notes.isEmpty { s += "\n" + notes.joined(separator: "\n") }
        return s
    }
}

public enum TemplateLoaderError: Error, LocalizedError {
    case noMesh
    public var errorDescription: String? { "USDZ 에 메시가 없습니다" }
}

@MainActor
public enum TemplateLoader {
    /// USDZ 를 읽어 (BustTemplate?, 보고서). 가장 정점이 많은 ModelEntity 를 Bust 로 본다 (이름이 "Bust" 면 우선).
    /// `manifest` 가 없으면 메시에서 임시 manifest 를 만든다(검증기는 당연히 실패 — 레거시 USDZ 용).
    public static func load(url: URL, manifest: TemplateManifest? = nil) async throws -> (template: BustTemplate?, report: TemplateLoadReport, root: Entity) {
        let start = Date()
        var report = TemplateLoadReport(url: url.path)
        let root = try await Entity(contentsOf: url)
        var models: [(Entity, ModelComponent)] = []
        func walk(_ e: Entity) {
            report.entityNames.append(e.name)
            if let m = e.components[ModelComponent.self] { models.append((e, m)) }
            for c in e.children { walk(c) }
        }
        walk(root)
        report.modelEntityCount = models.count
        guard !models.isEmpty else { report.notes.append("ModelComponent 가 없습니다"); return (nil, report, root) }

        // 선택: 이름 Bust 우선, 아니면 가장 큰 파트
        func partInfo(_ m: ModelComponent) -> (MeshResource.Part, Int)? {
            var best: (MeshResource.Part, Int)?
            for model in m.mesh.contents.models {
                for part in model.parts {
                    let n = part.positions.count
                    if best == nil || n > best!.1 { best = (part, n) }
                }
            }
            return best
        }
        var chosen: (Entity, ModelComponent, MeshResource.Part)?
        var bestShapeCount = -1
        for (e, m) in models {
            report.partCount += m.mesh.contents.models.reduce(0) { $0 + $1.parts.count }
            guard let (part, n) = partInfo(m) else { continue }
            // 엔티티별 셰이프 요약
            let comp = BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: m.mesh))
            let names = comp.weightSet.flatMap { $0.weightNames }
            var readable = 0
            for full in names {
                let short = full.split(separator: "/").last.map(String.init) ?? full
                if let b = part.blendShapeOffsets(named: full) ?? part.blendShapeOffsets(named: short), b.count == n { readable += 1 }
            }
            report.entities.append(.init(name: e.name, vertexCount: n, shapeNames: names.map { ($0.split(separator: "/").last.map(String.init) ?? $0).split(separator: ".").last.map(String.init) ?? $0 },
                                         readableOffsets: readable, hasJointInfluences: part.jointInfluences != nil))
            // 선택: 이름 Bust > 셰이프가 가장 많은 메시 > 가장 큰 메시
            let isBust = e.name == "Bust" || e.name.hasSuffix("/Bust")
            let better = chosen == nil || isBust || (!(chosen!.0.name == "Bust") && (names.count > bestShapeCount || (names.count == bestShapeCount && n > chosen!.2.positions.count)))
            if better { chosen = (e, m, part); bestShapeCount = names.count }
        }
        guard let (entity, model, part) = chosen else { throw TemplateLoaderError.noMesh }
        report.chosenEntity = entity.name
        // 파트 좌표는 메시 로컬 — 엔티티(루트 기준) 변환을 적용해 흉상 공간으로 (USD upAxis 변환·아마추어 변환 포함)
        // root(Entity(contentsOf:)) 자체도 USD 스테이지 변환(upAxis 등)을 가질 수 있으므로 월드 기준으로
        let toRoot = entity.transformMatrix(relativeTo: nil)
        do {
            let rc = root.transform.matrix.columns
            report.notes.append(String(format: "루트 변환: 열0 (%.2f %.2f %.2f) 열1 (%.2f %.2f %.2f) 열2 (%.2f %.2f %.2f)", rc.0.x, rc.0.y, rc.0.z, rc.1.x, rc.1.y, rc.1.z, rc.2.x, rc.2.y, rc.2.z))
        }
        let rawPositions = Array(part.positions.elements)
        let isIdentity = toRoot == matrix_identity_float4x4
        let positions = isIdentity ? rawPositions : rawPositions.map { Geometry.transformPoint(toRoot, $0) }
        if !isIdentity {
            let c = toRoot.columns
            report.notes.append(String(format: "엔티티 변환 적용: 열0 (%.2f %.2f %.2f) 열1 (%.2f %.2f %.2f) 열2 (%.2f %.2f %.2f) 이동 (%.3f %.3f %.3f)", c.0.x, c.0.y, c.0.z, c.1.x, c.1.y, c.1.z, c.2.x, c.2.y, c.2.z, c.3.x, c.3.y, c.3.z))
        }
        do {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            report.notes.append(String(format: "정점 범위 x %.3f…%.3f  y %.3f…%.3f  z %.3f…%.3f", lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))
        }
        let normals = part.normals.map { ns -> [SIMD3<Float>] in isIdentity ? Array(ns.elements) : ns.elements.map { simd_normalize(Geometry.transformDirection(toRoot, $0)) } }
        let uvs = part.textureCoordinates.map { Array($0.elements) }
        let indices = part.triangleIndices.map { Array($0.elements) } ?? []
        report.vertexCount = positions.count
        report.triangleCount = indices.count / 3
        report.hasNormals = normals != nil
        report.hasUVs = uvs != nil

        // 셰이프 이름 (전체 모델 기준) → 이 파트에서 읽히는지
        let mapping = BlendShapeWeightsMapping(meshResource: model.mesh)
        let comp = BlendShapeWeightsComponent(weightsMapping: mapping)
        var names: [String] = []
        for data in comp.weightSet { names.append(contentsOf: data.weightNames) }
        report.blendShapeNames = names.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        var deltas: [ArkitShape: [SIMD3<Float>]] = [:]
        if let first = names.first {
            let short = first.split(separator: "/").last.map(String.init) ?? first
            let bFull = part.blendShapeOffsets(named: first), bShort = part.blendShapeOffsets(named: short)
            report.notes.append("프로브: 첫 셰이프 '\(first)' → full \(bFull.map { "\($0.count)" } ?? "nil") · short '\(short)' \(bShort.map { "\($0.count)" } ?? "nil") · 파트 정점 \(positions.count)")
            report.notes.append("셰이프 이름 예: " + names.prefix(4).joined(separator: " | "))
            // 다른 파트에서 읽히는지 (모델에 파트가 여럿일 때)
            var partHits: [String] = []
            for model in model.mesh.contents.models { for p in model.parts { if let b = p.blendShapeOffsets(named: first) { partHits.append("\(p.id)(\(p.positions.count)):\(b.count)") } } }
            if !partHits.isEmpty { report.notes.append("오프셋 보유 파트: " + partHits.prefix(6).joined(separator: ", ")) }
        }
        for full in names {
            let short = full.split(separator: "/").last.map(String.init) ?? full
            let tail = short.split(separator: ".").last.map(String.init) ?? short
            let buf = part.blendShapeOffsets(named: full) ?? part.blendShapeOffsets(named: short) ?? part.blendShapeOffsets(named: tail)
            let ok = buf.map { $0.count == positions.count } ?? false
            report.readableOffsets[tail] = ok
            if ok, let buf, let shape = ArkitShape(rawValue: tail) { deltas[shape] = Array(buf.elements) }
        }
        if !names.isEmpty && report.offsetsReadableCount == 0 {
            report.notes.append("⚠️ 셰이프키 이름은 \(names.count)개 보이지만 blendShapeOffsets(named:) 가 모두 nil/길이 불일치 → bust.mesh 폴백 필요")
        }

        // 스켈레톤·스킨
        var skeleton: TemplateSkeleton? = nil
        var jointNamesAll: [String] = []
        for sk in model.mesh.contents.skeletons {
            report.skeletonIDs.append(sk.id)
            let jn = sk.joints.map(\.name)
            jointNamesAll = jn
            let parents = sk.joints.map { $0.parentIndex ?? -1 }
            let rest = sk.joints.map { $0.inverseBindPoseMatrix.inverse }
            skeleton = TemplateSkeleton(jointNames: jn, parentIndices: parents, restWorld: rest)
        }
        report.jointNames = jointNamesAll
        var skin: [SkinInfluence]? = nil
        if let ji = part.jointInfluences {
            let infl = Array(ji.influences.elements)
            report.jointInfluenceCount = infl.count
            // `influencesPerVertex` 는 init 전용(읽기 프로퍼티 없음) → 길이에서 역산
            let per = positions.isEmpty ? 0 : infl.count / positions.count
            report.influencesPerVertex = per
            if infl.count == positions.count * per {
                var out = [SkinInfluence](repeating: .none, count: positions.count)
                for v in 0..<positions.count {
                    var js = SIMD4<UInt16>(repeating: 0), ws = SIMD4<Float>(repeating: 0)
                    for k in 0..<min(4, per) {
                        let e = infl[v * per + k]
                        js[k] = UInt16(max(0, min(65535, e.jointIndex))); ws[k] = e.weight
                    }
                    let sum = ws.x + ws.y + ws.z + ws.w
                    if sum > 1e-6 { ws /= sum } else { ws = SIMD4(1, 0, 0, 0) }
                    out[v] = SkinInfluence(joints: js, weights: ws)
                }
                skin = out
            } else {
                report.notes.append("jointInfluences 길이(\(infl.count))가 정점 × 영향수(\(positions.count)×\(per))와 다릅니다")
            }
        }
        report.elapsed = Date().timeIntervalSince(start)

        guard positions.count >= 3, indices.count >= 3 else { return (nil, report, root) }
        let m: TemplateManifest
        if let manifest { m = manifest } else {
            let hash = ARKitFaceTopology.patchTriangleHash(indices: indices, patchCount: min(ARKitFaceTopology.vertexCount, positions.count))
            var tmp = TemplateManifest(id: "legacy-\(url.deletingPathExtension().lastPathComponent)", version: "0", vertexCount: positions.count,
                                       triangleCount: indices.count / 3, patchTriangleHash: ARKitFaceTopology.hexString(hash),
                                       landmarks: [:], groups: [:], shapeKeys: report.blendShapeNames)
            tmp.patchVertexCount = min(ARKitFaceTopology.vertexCount, positions.count)
            tmp.generator = "TemplateLoader(legacy, 계약 메타 없음)"
            tmp.boneRest = Dictionary(uniqueKeysWithValues: (skeleton?.jointNames ?? []).enumerated().map { (i, n) in
                let c = skeleton!.restWorld[i].columns.3
                return (n.split(separator: "/").last.map(String.init) ?? n, [c.x, c.y, c.z])
            })
            m = tmp
        }
        let uvArr = uvs ?? [SIMD2<Float>](repeating: .zero, count: positions.count)
        let template = BustTemplate(manifest: m, positions: positions, normals: normals, uvs: uvArr, indices: indices,
                                    shapeDeltas: deltas, skin: skin, skeleton: skeleton)
        return (template, report, root)
    }
}
