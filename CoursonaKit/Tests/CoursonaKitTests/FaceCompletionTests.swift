//
//  FaceCompletionTests.swift
//  CoursonaKitTests
//
//  C2 — 얼굴면 완성(A 등급): F4(SilhouetteFitter 눈·입 제외) · F8(CapBuilder 델타 재생성) · F9(SelfIntersectionCheck).
//  F5·F6(피팅 좌표로 다시 닫기)은 C1 의 `CapBuilder.addingCaps` 를 그대로 재사용하므로 따로 코드가 없다 —
//  `BustEntity` 가 피팅된 Identity 좌표를 템플릿에 대입한 뒤 같은 함수를 부른다(코드 리뷰로 확인, RealityKit
//  의존이라 패키지 테스트에서는 직접 구동하지 않는다).
//

import Testing
import simd
import CoursonaCore
import CoursonaFit
import CoursonaFace

@Suite("얼굴면 완성 (C2 — F4·F8·F9)")
struct FaceCompletionTests {

    @Test("F4: 눈·입 안쪽(LidInner·LipInner)은 실루엣이 움직이지 않는다")
    func silhouetteExcludesEyeMouthRegion() {
        var manifest = TemplateManifest(id: "t", version: "1.0", vertexCount: 20, triangleCount: 0, patchTriangleHash: "t",
                                        landmarks: [:], groups: ["Shoulders": [18, 19], "LidInner": [10, 11], "LipInner": [12, 13, 14]],
                                        shapeKeys: [])
        manifest.patchVertexCount = 8 // 0..<8 은 패치(항상 제외)
        let positions = (0..<20).map { SIMD3<Float>(Float($0) * 0.01, 0.3, 0) } // y=0.3 → 목 감쇠 구간(0.22…0.30) 위, 가중치 1
        let template = BustTemplate(manifest: manifest, positions: positions, uvs: positions.map { SIMD2($0.x, $0.z) },
                                    indices: [], shapeDeltas: [:])
        let (movable, _) = SilhouetteFitter.movableVertices(template: template, options: FitOptions())
        let movableSet = Set(movable)
        #expect(!movableSet.contains(10)); #expect(!movableSet.contains(11))   // LidInner
        #expect(!movableSet.contains(12)); #expect(!movableSet.contains(13)); #expect(!movableSet.contains(14)) // LipInner
        #expect(!movableSet.contains(18)); #expect(!movableSet.contains(19))   // Shoulders(원래도 제외)
        #expect(!movableSet.contains(0))                                        // 패치(원래도 제외)
        #expect(movableSet.contains(15)); #expect(movableSet.contains(16)); #expect(movableSet.contains(17)) // 나머지는 그대로 움직여야 한다
    }

    @Test("F4: 끄면(excludeEyeMouthRegion=false) 다시 움직인다 — 옵션이 실제로 반영된다")
    func silhouetteExclusionCanBeDisabled() {
        var manifest = TemplateManifest(id: "t", version: "1.0", vertexCount: 12, triangleCount: 0, patchTriangleHash: "t",
                                        landmarks: [:], groups: ["LidInner": [10, 11]], shapeKeys: [])
        manifest.patchVertexCount = 8
        let positions = (0..<12).map { SIMD3<Float>(Float($0) * 0.01, 0.3, 0) }
        let template = BustTemplate(manifest: manifest, positions: positions, uvs: positions.map { SIMD2($0.x, $0.z) },
                                    indices: [], shapeDeltas: [:])
        var opt = FitOptions(); opt.silhouette.excludeEyeMouthRegion = false
        let (movable, _) = SilhouetteFitter.movableVertices(template: template, options: opt)
        #expect(Set(movable).contains(10))
    }

    @Test("F8: 새 캡 정점(중간 고리+중심)은 테두리의 평균 델타를 물려받는다")
    func capBuilderPropagatesAverageDeltaToNewVertices() {
        let holeAt = (3, 3)
        var template = FaceSurfaceTests.makeHoleyTemplate(n: 9, spacing: 0.01, holeAt: holeAt)
        // 테두리 4점에 전부 같은 델타를 줘서 "평균 = 그 값" 을 쉽게 검증한다.
        let d = SIMD3<Float>(0, -0.004, 0.001)
        template.shapeDeltas[.eyeBlinkLeft] = [SIMD3<Float>](repeating: d, count: template.positions.count)

        let result = CapBuilder.addingCaps(to: template)
        let cap = try! #require(result.eyeLeft)
        #expect(cap.addedVertexIDs.count == cap.ringSize + 1) // 중간 고리 + 중심

        let deltas = try! #require(result.template.shapeDeltas[.eyeBlinkLeft])
        #expect(deltas.count == result.template.positions.count)
        for id in cap.addedVertexIDs {
            #expect(simd_length(deltas[id] - d) < 1e-6)
        }
        // 테두리(기존 정점)는 원래 델타를 그대로 유지한다.
        for id in cap.loopVertexIDs {
            #expect(simd_length(deltas[id] - d) < 1e-6)
        }
    }

    @Test("F9: 뒤틀린 셰이프는 캡 삼각형 뒤집힘을 잡아내고, 멀쩍한 셰이프는 0건이다")
    func selfIntersectionCheckDetectsFlippedCapTriangles() {
        let holeAt = (3, 3)
        var template = FaceSurfaceTests.makeHoleyTemplate(n: 9, spacing: 0.01, holeAt: holeAt)

        // "멀쩍한" 셰이프: 테두리 전부 같은 작은 델타(순수 평행이동) → 캡도 같이 평행이동, 삼각형 모양 안 바뀜.
        let gentle = SIMD3<Float>(0, 0, 0.0005)
        template.shapeDeltas[.eyeBlinkLeft] = [SIMD3<Float>](repeating: gentle, count: template.positions.count)

        // "뒤틀린" 셰이프: 테두리 4점 중 절반만 크게 밀어 지그재그를 만든다 — 캡(중간 고리)은 평균(= 작게)만 움직여
        // 밴드 삼각형이 뒤집히기 쉽다.
        var twisted = [SIMD3<Float>](repeating: .zero, count: template.positions.count)
        let loopIDs = template.manifest.group(.arkitFace).isEmpty ? [] : [Int]() // (사용 안 함, 아래서 직접 찾는다)
        _ = loopIDs
        // 구멍 네 모서리 id 를 직접 계산(FaceSurfaceTests.grid 와 같은 규칙: id = z*n + x)
        func vid(_ x: Int, _ z: Int) -> Int { z * 9 + x }
        let corners = [vid(holeAt.0, holeAt.1), vid(holeAt.0 + 1, holeAt.1), vid(holeAt.0 + 1, holeAt.1 + 1), vid(holeAt.0, holeAt.1 + 1)]
        for (k, id) in corners.enumerated() { twisted[id] = k % 2 == 0 ? SIMD3(0, 0, 0.05) : .zero }
        template.shapeDeltas[.jawOpen] = twisted

        let result = CapBuilder.addingCaps(to: template)
        #expect(result.eyeLeft != nil)
        let reports = SelfIntersectionCheck.check(result)
        let flaggedShapes = Set(reports.map(\.shape))
        #expect(!flaggedShapes.contains(.eyeBlinkLeft))
        #expect(flaggedShapes.contains(.jawOpen))
    }
}
