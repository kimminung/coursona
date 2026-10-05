import Testing
import CoreGraphics
@testable import CoursonaCapture

/// T-302: 얼굴 상자 안 그리드 샘플링 비율(순수 로직 — Vision 비의존).
@Suite("인물 매트 그리드 샘플링 (T-302)")
struct PersonCoverageTests {
    @Test("샘플이 전부 사람(1)이면 비율 1")
    func allPerson() {
        let r = PersonCoverage.ratio(faceBoxImageCoords: CGRect(x: 10, y: 10, width: 100, height: 100)) { _ in 1 }
        #expect(r == 1)
    }

    @Test("샘플이 전부 배경(0)이면 비율 0")
    func allBackground() {
        let r = PersonCoverage.ratio(faceBoxImageCoords: CGRect(x: 10, y: 10, width: 100, height: 100)) { _ in 0 }
        #expect(r == 0)
    }

    @Test("절반만 사람이면 비율도 절반 근처")
    func halfPerson() {
        // 상자 왼쪽 절반은 사람(1), 오른쪽 절반은 배경(0) — x 좌표로 판정.
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r = PersonCoverage.ratio(faceBoxImageCoords: box) { point in point.x < 50 ? 1 : 0 }
        #expect(abs(r - 0.5) < 0.1, "비율 \(r)")
    }

    @Test("상자가 비어 있으면(폭 또는 높이 0) 항상 통과(1)")
    func emptyBoxPasses() {
        var calls = 0
        let r = PersonCoverage.ratio(faceBoxImageCoords: .zero) { _ in calls += 1; return 0 }
        #expect(r == 1 && calls == 0)
    }

    @Test("그리드 수를 바꿔도 비율 계산이 맞는다(3×3=9점)")
    func customGrid() {
        var count = 0
        let r = PersonCoverage.ratio(faceBoxImageCoords: CGRect(x: 0, y: 0, width: 30, height: 30), grid: 3) { _ in count += 1; return 1 }
        #expect(count == 9 && r == 1)
    }
}
