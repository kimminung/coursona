import Testing
import simd
@testable import CoursonaCore
@testable import CoursonaFace

/// C5 T-501: 캡(눈·입) 전용 UV 섬 — `manifest.uvRegions["cap_eye_L"/"cap_eye_R"/"cap_mouth"]` 이 있으면
/// 그 사각형 안에, 없으면(옛 동작) 바깥 고리 UV 를 상속해 닫는다. `SyntheticTemplate.make()` 는 구멍이 없는
/// 워터타이트 메시라(FitTests 등이 전제) `FaceSurfaceTests` 의 평면 격자 픽스처를 그대로 가져와 쓴다.
@Suite("캡 UV 섬 (C5, T-501)")
struct CapUVIslandTests {
    @Test("섬이 있으면 캡 정점 UV 가 그 사각형 안에 들어가고, 바깥 고리 UV 를 그대로 베끼지 않는다")
    func dedicatedIslandUsed() throws {
        var t = FaceSurfaceTests.makeHoleyTemplate(n: 9, spacing: 0.01, holeAt: (3, 3))
        let region: [Float] = [0.80, 0.90, 0.88, 0.98]
        t.manifest.uvRegions["cap_eye_L"] = region
        let result = CapBuilder.addingCaps(to: t)
        let cap = try #require(result.eyeLeft)
        let template = result.template
        let loopUVs = Set(cap.loopVertexIDs.map { template.uvs[$0] })

        func inside(_ uv: SIMD2<Float>) -> Bool {
            uv.x >= region[0] - 1e-4 && uv.x <= region[2] + 1e-4 && uv.y >= region[1] - 1e-4 && uv.y <= region[3] + 1e-4
        }
        for id in cap.addedVertexIDs {
            let uv = template.uvs[id]
            #expect(inside(uv), "정점 \(id) UV \(uv) 가 섬 \(region) 밖")
            #expect(!loopUVs.contains(uv), "정점 \(id) UV \(uv) 가 바깥 고리 UV 를 그대로 베낌")
        }
    }

    @Test("섬 정의가 없으면(옛 템플릿) 바깥 고리 UV 를 그대로 물려받는다")
    func fallsBackWithoutIsland() throws {
        let t = FaceSurfaceTests.makeHoleyTemplate(n: 9, spacing: 0.01, holeAt: (3, 3))
        #expect(t.manifest.uvRegions["cap_eye_L"] == nil)
        let result = CapBuilder.addingCaps(to: t)
        let cap = try #require(result.eyeLeft)
        let template = result.template
        // 중간 고리(ring) 정점은 옛 동작에서 loop[i] 의 UV 를 그대로 받는다(순서대로) — 중심은 loop[0] 의 UV.
        let midRing = Array(cap.addedVertexIDs.dropLast())
        for (i, id) in midRing.enumerated() {
            #expect(template.uvs[id] == t.uvs[cap.loopVertexIDs[i]])
        }
        #expect(template.uvs[cap.addedVertexIDs.last!] == t.uvs[cap.loopVertexIDs[0]])
    }

    @Test("합성 전신 템플릿의 세 캡 섬(cap_eye_L/R·cap_mouth)은 서로 겹치지 않는다")
    func islandsDoNotOverlap() {
        let t = SyntheticTemplate.make()
        let regions = ["cap_eye_L", "cap_eye_R", "cap_mouth"].compactMap { t.manifest.uvRegions[$0] }
        #expect(regions.count == 3)
        func overlaps(_ a: [Float], _ b: [Float]) -> Bool {
            a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
        }
        for i in 0..<regions.count {
            for j in (i + 1)..<regions.count {
                #expect(!overlaps(regions[i], regions[j]), "섬 \(i)·\(j) 겹침")
            }
        }
    }
}
