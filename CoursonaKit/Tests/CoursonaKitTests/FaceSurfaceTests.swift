//
//  FaceSurfaceTests.swift
//  CoursonaKitTests
//
//  T-101(FaceSurfacePartitioner)·T-102(CapBuilder)·T-104(단위 테스트) — 눈·입 구멍을 위상(경계 변)으로
//  찾아 닫는 알고리즘을 평면 격자로 검증한다. 실제 블렌더 흉상(bust.mesh)은 앱 번들 리소스라 패키지
//  테스트에서는 못 읽는다 — 여기서는 "임의의 구멍을 가진 메시"로 알고리즘 자체를 확인한다.
//

import Testing
import simd
import CoursonaCore
import CoursonaFace

@Suite("얼굴면·캡 (T-101/102)")
struct FaceSurfaceTests {

    /// n×n 평면 격자(사각형 → 삼각형 2개)를 만들고, `holeAt` 칸 하나를 비워 네모 구멍을 낸다.
    static func grid(n: Int, spacing: Float, holeAt: (Int, Int)?) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        func vid(_ x: Int, _ z: Int) -> Int { z * n + x }
        var positions: [SIMD3<Float>] = []
        for z in 0..<n { for x in 0..<n { positions.append(SIMD3(Float(x) * spacing, 0, Float(z) * spacing)) } }
        var indices: [UInt32] = []
        for z in 0..<(n - 1) {
            for x in 0..<(n - 1) {
                if let h = holeAt, h.0 == x, h.1 == z { continue }
                let a = vid(x, z), b = vid(x + 1, z), c = vid(x + 1, z + 1), d = vid(x, z + 1)
                indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
                indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(d)])
            }
        }
        return (positions, indices)
    }

    static func makeHoleyTemplate(n: Int, spacing: Float, holeAt: (Int, Int)) -> BustTemplate {
        let (positions, indices) = grid(n: n, spacing: spacing, holeAt: holeAt)
        let uvs = positions.map { SIMD2<Float>($0.x, $0.z) }
        var manifest = TemplateManifest(id: "test-grid", version: "1.0", vertexCount: positions.count, triangleCount: indices.count / 3,
                                        patchTriangleHash: "test", landmarks: [:], groups: [:], shapeKeys: [])
        let seed = SIMD3<Float>((Float(holeAt.0) + 0.5) * spacing, 0, (Float(holeAt.1) + 0.5) * spacing)
        manifest.eyeL = [seed.x, seed.y, seed.z]
        manifest.eyeR = [10, 10, 10]   // 멀리 둬서 안 걸리게 — "딴 구멍(목·어깨)과 혼동하지 않는다" 를 검증
        manifest.mouthCenter = [10, 10, 10]
        return BustTemplate(manifest: manifest, positions: positions, uvs: uvs, indices: indices, shapeDeltas: [:])
    }

    @Test("경계 고리: 평면 격자의 네모 구멍(4점)과 바깥 테두리를 둘 다 찾는다")
    func boundaryLoopsFindsHoleAndOuterRim() {
        let (_, indices) = Self.grid(n: 9, spacing: 0.01, holeAt: (3, 3))
        let loops = Geometry.boundaryLoops(indices: indices)
        #expect(loops.count == 2)
        #expect(loops.map(\.count).sorted().first == 4)
    }

    @Test("CapBuilder: 시드(눈) 근처 구멍만 닫고 먼 구멍(바깥 테두리)은 그대로 둔다 — 자기 일치·워터타이트(T-104)")
    func capBuilderClosesOnlySeededHole() {
        let holeAt = (3, 3)
        let template = Self.makeHoleyTemplate(n: 9, spacing: 0.01, holeAt: holeAt)
        #expect(Geometry.boundaryLoops(indices: template.indices).count == 2)

        let result = CapBuilder.addingCaps(to: template)
        #expect(result.eyeLeft?.ringSize == 4)
        #expect(result.eyeRight == nil) // 시드가 멀어서 안 닫힘 — 엉뚱한 구멍을 막지 않는다
        #expect(result.mouth == nil)

        // 워터타이트: 구멍은 닫히고 바깥 테두리(32점) 하나만 남는다.
        let after = Geometry.boundaryLoops(indices: result.template.indices)
        #expect(after.count == 1)
        #expect((after.first?.count ?? 0) == 32)

        // 자기 일치: 더해진 정점·삼각형 수가 공식(중간 고리 ring.count + 중심 1 / 삼각형 ring.count*3)과 정확히 맞는다.
        let addedVerts = result.template.positions.count - template.positions.count
        let addedTris = result.template.indices.count / 3 - template.indices.count / 3
        #expect(addedVerts == 4 + 1)
        #expect(addedTris == 4 * 3)
        #expect(result.addedVertexIDs.count == addedVerts)
        #expect(result.template.manifest.vertexCount == result.template.positions.count)
        #expect(result.template.manifest.triangleCount == result.template.indices.count / 3)
    }

    @Test("CapBuilder: 시드 근처에 구멍이 없으면 조용히 건너뛴다(합성 템플릿처럼) — 엉뚱한 테두리를 막지 않는다")
    func capBuilderSkipsWhenNoHoleNearSeed() {
        let (positions, indices) = Self.grid(n: 5, spacing: 0.01, holeAt: nil) // 구멍 없음, 바깥 테두리만(그 자체도 "경계"지만 시드와는 멀다)
        let uvs = positions.map { SIMD2<Float>($0.x, $0.z) }
        var manifest = TemplateManifest(id: "t", version: "1.0", vertexCount: positions.count, triangleCount: indices.count / 3,
                                        patchTriangleHash: "t", landmarks: [:], groups: [:], shapeKeys: [])
        manifest.eyeL = [10, 10, 10]; manifest.eyeR = [11, 10, 10]; manifest.mouthCenter = [12, 10, 10]
        let template = BustTemplate(manifest: manifest, positions: positions, uvs: uvs, indices: indices, shapeDeltas: [:])
        let result = CapBuilder.addingCaps(to: template)
        #expect(result.eyeLeft == nil); #expect(result.eyeRight == nil); #expect(result.mouth == nil)
        #expect(result.template.positions.count == template.positions.count)
    }

    @Test("FaceSurfacePartitioner: 얼굴 정점 집합에 속한 삼각형이 앞쪽에 모인다")
    func faceSurfacePartitionOrdersFaceTrianglesFirst() {
        // 2행 3열 평면(정점 6개): 왼쪽 사각형(0,1,4,3) = 얼굴, 오른쪽 사각형(1,2,5,4) = 아님.
        let positions: [SIMD3<Float>] = (0..<6).map { SIMD3(Float($0 % 3) * 0.01, 0, Float($0 / 3) * 0.01) }
        let uvs = positions.map { SIMD2<Float>($0.x, $0.z) }
        let indices: [UInt32] = [0, 1, 4, 0, 4, 3, 1, 2, 5, 1, 5, 4]
        let manifest = TemplateManifest(id: "t", version: "1.0", vertexCount: positions.count, triangleCount: indices.count / 3,
                                        patchTriangleHash: "t", landmarks: [:], groups: ["ARKitFace": [0, 1, 3, 4]], shapeKeys: [])
        let template = BustTemplate(manifest: manifest, positions: positions, uvs: uvs, indices: indices, shapeDeltas: [:])
        let partition = FaceSurfacePartitioner.partition(template: template)
        #expect(partition.faceTriangleCount == 2)
        #expect(partition.restTriangleCount == 2)
        let faceSet: Set<UInt32> = [0, 1, 3, 4]
        for i in 0..<partition.faceIndexCount { #expect(faceSet.contains(partition.indices[i])) }
    }

    @Test("FaceSurfacePartitioner: capIndexRanges 를 주면 재배열 뒤 캡 삼각형 구간을 같은 순서·내용으로 돌려준다(C6, T-604)")
    func capRangesAreRemappedCorrectly() throws {
        let template = Self.makeHoleyTemplate(n: 9, spacing: 0.01, holeAt: (3, 3))
        let capped = CapBuilder.addingCaps(to: template)
        let cap = try #require(capped.eyeLeft)
        let partition = FaceSurfacePartitioner.partition(template: capped.template, additionalFaceVertexIDs: capped.addedVertexIDs,
                                                         capIndexRanges: capped.caps.map(\.triangleIndexRange))
        #expect(partition.capRanges.count == 1)
        let mapped = partition.capRanges[0]
        #expect(mapped.count == cap.triangleIndexRange.count)
        // 얼굴면 블록 안쪽에 있어야 한다(나머지 블록으로 새지 않는다).
        #expect(mapped.upperBound <= partition.faceIndexCount)
        // 캡 삼각형들의 상대 순서·내용은 재배열 전과 똑같다 — 다른 얼굴면 삼각형이 앞에 끼어들 뿐.
        #expect(Array(partition.indices[mapped]) == Array(capped.template.indices[cap.triangleIndexRange]))
    }
}
