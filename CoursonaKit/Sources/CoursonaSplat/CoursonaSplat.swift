//
//  CoursonaSplat.swift
//  CoursonaSplat
//
//  얼굴면 밖 입체감(가우시안 스플랫) 모듈 — 신규(TechPRD §6.6). 학습 없음, 바인딩 + 초기화만.
//
//  C5(T-503): `SplatBinder` 가 `BustEntity`/`TextureBuilder` 와 같은 패턴(피팅된 좌표 대입 → `CapBuilder.addingCaps`)
//  으로 캡을 닫은 뒤, **얼굴면 밖**(얼굴 패치·눈꺼풀/입술 안쪽·캡이 아닌 모든 삼각형 — `TextureBuilder.isFaceTri`
//  의 정반대) 삼각형마다 스플랫을 1~3개(면적 비례) 바인딩한다. 총 개수는 `maxSplats`(기본 60k)로 예산을 맞춘다.
//  색은 `TextureBuilder`(`faceOnlyPreset`)가 만든 `splatColor`(512² 기본)에서 그 자리의 UV 로 샘플링하고,
//  관측이 없으면(알파 0) 영역별 기본색(두피/목·귀/어깨)으로 떨어진다 — §6.5/§6.6 이 정확히 이 그림으로 설계됐다.
//
//  아직 안 한 것(T-504): `GaussianSplatResource`/`GaussianSplatComponent` 브리지, 시뮬레이터·실패 폴백.
//  `splats.bin` 직렬화는 `SplatFile.swift`.
//

import Foundation
import simd
import CoursonaCore
import CoursonaFace

public struct SplatBuildOptions: Sendable {
    /// §6.6: 총 스플랫 수 상한.
    public var maxSplats = 60_000
    /// 무게중심에서 법선 방향으로 띄우는 거리(m).
    public var normalOffset: Float = 0.0015
    /// 주축 스케일 = 삼각형 외접원 반지름 × 이 값.
    public var majorScaleFactor: Float = 0.9
    /// 단축(법선 방향) 스케일 = 주축 × 이 비율.
    public var minorScaleRatio: Float = 1.0 / 3.0
    /// 목·어깨는 스케일을 이 배로 키운다(§6.6).
    public var neckShoulderScaleBoost: Float = 1.3
    /// 두피 겹 수(머리카락 두께 느낌) — 1 이면 보통 삼각형과 같다.
    public var scalpLayers = 2
    /// 두피 바깥 겹을 추가로 띄우는 거리(m).
    public var scalpLayerOffset: Float = 0.003
    public var skinOpacity: Float = 0.95
    /// 두피 바깥 겹(마지막 레이어)의 불투명도.
    public var scalpOuterOpacity: Float = 0.6
    /// 얼굴면 경계에 맞닿은 바깥 몇 겹(정점 공유 기준)은 이음매가 안 보이게 완전 불투명.
    public var rimOpacity: Float = 1.0
    public var rimRings = 2
    public init() {}
}

/// 스플랫 하나. 앞 5개 필드가 렌더용("데이터"), 뒤 4개가 재계산용("바인딩" — 삼각형이 변형되면 다시 구울 수 있다, v1.1).
public struct SplatRecord: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var rotation: simd_quatf
    /// 0...1 선형 RGB(§6.6 SH 0차 — 방향별 반사율 차이는 다루지 않는다).
    public var color: SIMD3<Float>
    public var opacity: Float
    public var triangle: Int32
    public var baryU: Float
    public var baryV: Float
    public var normalOffset: Float
    public init(position: SIMD3<Float>, scale: SIMD3<Float>, rotation: simd_quatf, color: SIMD3<Float>, opacity: Float,
                triangle: Int32, baryU: Float, baryV: Float, normalOffset: Float) {
        self.position = position; self.scale = scale; self.rotation = rotation; self.color = color; self.opacity = opacity
        self.triangle = triangle; self.baryU = baryU; self.baryV = baryV; self.normalOffset = normalOffset
    }
}

public struct SplatBuildResult: Sendable {
    public var records: [SplatRecord]
    public var faceTriangleCount: Int
    public var nonFaceTriangleCount: Int
    public init(records: [SplatRecord], faceTriangleCount: Int, nonFaceTriangleCount: Int) {
        self.records = records; self.faceTriangleCount = faceTriangleCount; self.nonFaceTriangleCount = nonFaceTriangleCount
    }
}

public enum SplatBinder {
    /// 삼각형 하나 안에서 n 개 스플랫을 둘 자리(무게중심 쪽으로 치우친 결정적 바리센트릭 좌표).
    static let barySets: [[SIMD3<Float>]] = [
        [],
        [SIMD3(1.0 / 3, 1.0 / 3, 1.0 / 3)],
        [SIMD3(0.6, 0.2, 0.2), SIMD3(0.2, 0.6, 0.2)],
        [SIMD3(0.6, 0.2, 0.2), SIMD3(0.2, 0.6, 0.2), SIMD3(0.2, 0.2, 0.6)],
    ]

    public static func build(template t: BustTemplate, identity: Identity, splatColor: RGBAImage? = nil,
                             fallbackSkin: SIMD3<Float> = SIMD3(0.70, 0.55, 0.45), options o: SplatBuildOptions = SplatBuildOptions()) -> SplatBuildResult {
        // C5(T-502)와 같은 패턴: 피팅된 좌표를 넣고 캡을 닫은 뒤 그 메시로 작업한다.
        var fittedForCaps = t
        if identity.positions.count == t.vertexCount { fittedForCaps.positions = identity.positions }
        let capResult = CapBuilder.addingCaps(to: fittedForCaps)
        let t = capResult.template
        let render = t.makeRenderMesh()
        let positions = render.expand(t.positions)
        let normals = Geometry.vertexNormals(positions: positions, indices: render.indices)
        let triCount = render.indices.count / 3
        guard triCount > 0 else { return SplatBuildResult(records: [], faceTriangleCount: 0, nonFaceTriangleCount: 0) }

        func triAll(_ set: Set<Int>) -> [Bool] {
            (0..<triCount).map { tri in (0..<3).allSatisfy { set.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) } }
        }
        // `TextureBuilder.isFaceTri` 와 같은 정의 — 얼굴면 = 패치 ∪ 눈꺼풀/입술 안쪽 ∪ 캡.
        let triPatch = triAll(Set(0..<t.patchCount))
        let triLidInner = triAll(Set(t.manifest.group(.lidInner)))
        let triLipInner = triAll(Set(t.manifest.group(.lipInner)))
        let capTriRanges: [Range<Int>] = capResult.caps.map { $0.triangleIndexRange.lowerBound / 3 ..< $0.triangleIndexRange.upperBound / 3 }
        let isFaceTri: [Bool] = (0..<triCount).map { tri in
            triPatch[tri] || triLidInner[tri] || triLipInner[tri] || capTriRanges.contains { $0.contains(tri) }
        }
        let triScalp = triAll(Set(t.manifest.group(.scalp)))
        let triShoulders = triAll(Set(t.manifest.group(.shoulders)))
        let neckSet = Set(t.manifest.group(.neck))
        let triNeck: [Bool] = (0..<triCount).map { tri in
            !triShoulders[tri] && (0..<3).allSatisfy { neckSet.contains(Int(render.sourceIndex[Int(render.indices[tri * 3 + $0])])) }
        }

        let nonFaceTriangles = (0..<triCount).filter { !isFaceTri[$0] }
        guard !nonFaceTriangles.isEmpty else { return SplatBuildResult(records: [], faceTriangleCount: triCount, nonFaceTriangleCount: 0) }

        // 림(바깥 몇 겹): 얼굴면과 정점을 공유하는 비얼굴 삼각형부터 BFS로 `rimRings` 까지 퍼뜨린다 — 이음매 안 보이게 완전 불투명.
        var vertexTris: [Int: [Int]] = [:]
        for tri in 0..<triCount { for c in 0..<3 { vertexTris[Int(render.indices[tri * 3 + c]), default: []].append(tri) } }
        var ring: [Int: Int] = [:]
        var frontier: Set<Int> = []
        for tri in nonFaceTriangles {
            let verts = (0..<3).map { Int(render.indices[tri * 3 + $0]) }
            if verts.contains(where: { vid in (vertexTris[vid] ?? []).contains { isFaceTri[$0] } }) { ring[tri] = 1; frontier.insert(tri) }
        }
        var depth = 1
        while depth < o.rimRings, !frontier.isEmpty {
            var next: Set<Int> = []
            for tri in frontier {
                for c in 0..<3 {
                    for n in vertexTris[Int(render.indices[tri * 3 + c])] ?? [] where !isFaceTri[n] && ring[n] == nil {
                        ring[n] = depth + 1; next.insert(n)
                    }
                }
            }
            frontier = next; depth += 1
        }

        func area(_ tri: Int) -> Float {
            let a = positions[Int(render.indices[tri * 3])], b = positions[Int(render.indices[tri * 3 + 1])], c = positions[Int(render.indices[tri * 3 + 2])]
            return simd_length(simd_cross(b - a, c - a)) / 2
        }
        let areas = nonFaceTriangles.map(area)
        let totalArea = max(1e-9, areas.reduce(0, +))
        // 레이어(두피 2겹)까지 고려한 예산: 두피 삼각형은 자리 수가 그대로에 레이어만 늘어나므로, 평균 스플랫 면적을
        // 살짝 넉넉하게 잡아 총 개수가 상한을 크게 넘지 않게 한다(정확한 상한 보장은 아래서 한 번 더 자른다).
        let avgSplatArea = totalArea / Float(max(1, min(o.maxSplats, nonFaceTriangles.count * 2)))

        func uv(_ tri: Int, _ bary: SIMD3<Float>) -> SIMD2<Float> {
            let a = render.uvs[Int(render.indices[tri * 3])], b = render.uvs[Int(render.indices[tri * 3 + 1])], c = render.uvs[Int(render.indices[tri * 3 + 2])]
            return a * bary.x + b * bary.y + c * bary.z
        }
        func colorAt(_ tri: Int, _ bary: SIMD3<Float>) -> SIMD3<Float> {
            if let img = splatColor {
                let p = uv(tri, bary)
                let px = SIMD2<Float>(p.x * Float(img.width), (1 - p.y) * Float(img.height))
                if let s = img.sample(px), s.w > 0.01 { return SIMD3(s.x, s.y, s.z) }
            }
            return fallbackSkin
        }
        /// 접평면 기저(법선 = 로컬 +Z)로 만든 회전.
        func tangentRotation(_ tri: Int, normal: SIMD3<Float>) -> simd_quatf {
            let a = positions[Int(render.indices[tri * 3])], b = positions[Int(render.indices[tri * 3 + 1])]
            var tangent = b - a
            let d = simd_dot(tangent, normal)
            tangent -= normal * d
            let len = simd_length(tangent)
            let x = len > 1e-9 ? tangent / len : Geometry.slerpUnit(SIMD3(1, 0, 0), SIMD3(0, 1, 0), 0) // 퇴화 삼각형 폴백
            let y = simd_cross(normal, x)
            let m = simd_float3x3(columns: (x, y, normal))
            return simd_quatf(m)
        }

        var records: [SplatRecord] = []
        records.reserveCapacity(min(o.maxSplats, nonFaceTriangles.count * 2))
        for (tri, a) in zip(nonFaceTriangles, areas) {
            var n = max(1, min(3, Int((a / avgSplatArea).rounded())))
            n = min(n, barySets.count - 1)
            let layers = triScalp[tri] ? max(1, o.scalpLayers) : 1
            let p0 = positions[Int(render.indices[tri * 3])], p1 = positions[Int(render.indices[tri * 3 + 1])], p2 = positions[Int(render.indices[tri * 3 + 2])]
            let n0 = normals[Int(render.indices[tri * 3])], n1 = normals[Int(render.indices[tri * 3 + 1])], n2 = normals[Int(render.indices[tri * 3 + 2])]
            // 외접원 반지름(둔각 삼각형에서도 쓸만한 근사: 변 길이로 공식 r = abc/4K).
            let lab = simd_length(p1 - p0), lbc = simd_length(p2 - p1), lca = simd_length(p0 - p2)
            let circumR = max(1e-5, (lab * lbc * lca) / max(1e-9, 4 * a))
            let majorScale = circumR * o.majorScaleFactor * (triNeck[tri] || triShoulders[tri] ? o.neckShoulderScaleBoost : 1)
            let scale = SIMD3<Float>(majorScale, majorScale, majorScale * o.minorScaleRatio)
            let baseOpacity: Float = (ring[tri] ?? .max) <= o.rimRings ? o.rimOpacity : o.skinOpacity

            for bary in barySets[n] {
                let pos = p0 * bary.x + p1 * bary.y + p2 * bary.z
                let nrm = simd_normalize(n0 * bary.x + n1 * bary.y + n2 * bary.z)
                let rot = tangentRotation(tri, normal: nrm)
                let col = colorAt(tri, bary)
                for layer in 0..<layers {
                    let offset = o.normalOffset + Float(layer) * o.scalpLayerOffset
                    let opacity = layer == layers - 1 && layers > 1 ? o.scalpOuterOpacity : baseOpacity
                    records.append(SplatRecord(position: pos + nrm * offset, scale: scale, rotation: rot, color: col, opacity: opacity,
                                               triangle: Int32(tri), baryU: bary.x, baryV: bary.y, normalOffset: offset))
                }
            }
        }
        // 예산 초과 시 면적이 큰 쪽(시각적으로 더 중요)을 남기고 균등 솎아낸다.
        if records.count > o.maxSplats {
            let stride = Double(records.count) / Double(o.maxSplats)
            var kept: [SplatRecord] = []; kept.reserveCapacity(o.maxSplats)
            var i = 0.0
            while kept.count < o.maxSplats, Int(i) < records.count { kept.append(records[Int(i)]); i += stride }
            records = kept
        }
        return SplatBuildResult(records: records, faceTriangleCount: triCount - nonFaceTriangles.count, nonFaceTriangleCount: nonFaceTriangles.count)
    }
}
