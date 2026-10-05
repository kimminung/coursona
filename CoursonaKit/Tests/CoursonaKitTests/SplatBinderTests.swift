import Testing
import simd
@testable import CoursonaCore
@testable import CoursonaSplat

/// C5 T-503: 얼굴면 밖 삼각형에 스플랫 바인딩.
@Suite("스플랫 바인딩 (C5, T-503)")
struct SplatBinderTests {
    static let template = SyntheticTemplate.make()

    @Test("얼굴면 밖 삼각형마다 스플랫이 생기고, 합이 상한을 넘지 않는다")
    func bindsNonFaceTriangles() {
        let t = Self.template
        let id = Identity.fromTemplate(t)
        let r = SplatBinder.build(template: t, identity: id)
        #expect(r.nonFaceTriangleCount > 0)
        #expect(r.faceTriangleCount > 0)
        #expect(!r.records.isEmpty)
        #expect(r.records.count <= SplatBuildOptions().maxSplats)
    }

    @Test("상한을 낮게 주면 실제로 그 이하로 솎아낸다")
    func respectsLowerBudget() {
        let t = Self.template
        let id = Identity.fromTemplate(t)
        var o = SplatBuildOptions(); o.maxSplats = 200
        let r = SplatBinder.build(template: t, identity: id, options: o)
        #expect(r.records.count <= 200)
        #expect(r.records.count > 0)
    }

    @Test("모든 레코드의 스케일·불투명도가 유효한 범위(양수, NaN 아님)")
    func recordsAreWellFormed() {
        let t = Self.template
        let id = Identity.fromTemplate(t)
        let r = SplatBinder.build(template: t, identity: id)
        for rec in r.records {
            #expect(rec.scale.x > 0 && rec.scale.y > 0 && rec.scale.z > 0)
            #expect(!rec.scale.x.isNaN && !rec.position.x.isNaN)
            #expect(rec.opacity > 0 && rec.opacity <= 1)
            #expect(rec.triangle >= 0)
        }
    }

    @Test("splatColor 가 없으면 전부 기본 피부색으로 떨어진다")
    func fallsBackToSkinColorWithoutSplatColor() {
        let t = Self.template
        let id = Identity.fromTemplate(t)
        let skin = SIMD3<Float>(0.5, 0.3, 0.2)
        let r = SplatBinder.build(template: t, identity: id, splatColor: nil, fallbackSkin: skin)
        #expect(r.records.allSatisfy { $0.color == skin })
    }

    @Test("splatColor 를 주면 거기서 색을 읽어 기본 피부색과 달라진다")
    func usesSplatColorWhenProvided() {
        let t = Self.template
        let id = Identity.fromTemplate(t)
        let img = RGBAImage(width: 32, height: 32, fill: SIMD4(10, 200, 30, 255)) // 선명한 초록, 완전 불투명
        let skin = SIMD3<Float>(0.5, 0.3, 0.2)
        let r = SplatBinder.build(template: t, identity: id, splatColor: img, fallbackSkin: skin)
        let differing = r.records.filter { $0.color != skin }
        #expect(!differing.isEmpty, "splatColor 가 있는데도 전부 기본색이면 샘플링이 안 된 것")
        if let one = differing.first { #expect(abs(one.color.y - 200.0 / 255.0) < 0.05) }
    }

    @Test("두피 삼각형은 레이어(2겹) 때문에 같은 (삼각형,바리센트릭) 자리에 기록이 2개 생긴다")
    func scalpGetsExtraLayer() {
        let t = Self.template
        let id = Identity.fromTemplate(t)
        var o = SplatBuildOptions(); o.scalpLayers = 2; o.maxSplats = 1_000_000 // 솎아내기 없이 전부 확인
        let r = SplatBinder.build(template: t, identity: id, options: o)
        let scalpSet = Set(t.manifest.group(.scalp))
        #expect(!scalpSet.isEmpty, "합성 템플릿에 두피 그룹이 없음 — 테스트 전제가 깨짐")

        var countByKey: [String: Int] = [:]
        for rec in r.records { countByKey["\(rec.triangle)-\(rec.baryU)-\(rec.baryV)", default: 0] += 1 }
        #expect(countByKey.values.contains { $0 == 2 }, "두피 2겹이 기록에 반영되지 않음(같은 자리에 레코드 2개가 있어야 한다)")
        // 1겹짜리(비두피) 자리도 있어야 한다 — 전부 2겹이면 scalpLayers 가 조건 없이 모두에 적용된 것일 수 있다.
        #expect(countByKey.values.contains { $0 == 1 }, "모든 자리가 2겹 — scalpLayers 가 두피가 아닌 곳에도 적용된 것으로 보임")
    }
}
