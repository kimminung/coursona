import Testing
import Foundation
import SwiftData
@testable import CoursonaIO

/// 이름으로 트루뎁스(A 등급) 스케일을 고정·재적용하는 저장소 (2026-10-09).
@MainActor
@Suite("트루뎁스 이름 기준 저장소")
struct TrueDepthAnchorStoreTests {
    /// 앱이 쓰는 공유(디스크) 컨텍스트를 건드리지 않도록 테스트마다 인메모리 컨텍스트를 새로 만든다.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: TrueDepthAnchor.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test("매칭 규칙: 부분 문자열 포함 + 가장 긴 기준 이름 우선 + 대소문자 무시")
    func matchingRule() {
        #expect(TrueDepthAnchorStore.bestMatch(for: "김콜슨 생일", among: ["김콜슨"]) == "김콜슨")
        #expect(TrueDepthAnchorStore.bestMatch(for: "김콜슨2", among: ["김콜슨"]) == "김콜슨")
        // "김콜슨"과 "김콜슨 생일" 둘 다 후보에 포함되면 더 긴(더 구체적인) 쪽이 이긴다.
        #expect(TrueDepthAnchorStore.bestMatch(for: "김콜슨 생일 파티", among: ["김콜슨", "김콜슨 생일"]) == "김콜슨 생일")
        #expect(TrueDepthAnchorStore.bestMatch(for: "Kim Coulson", among: ["kim coulson"]) == "kim coulson")
        #expect(TrueDepthAnchorStore.bestMatch(for: "전혀 다른 사람", among: ["김콜슨"]) == nil)
        // 빈 기준 이름은 모든 이름에 포함된다고 쳐서 오매칭으로 이어질 수 있으니 항상 제외한다.
        #expect(TrueDepthAnchorStore.bestMatch(for: "아무개", among: [""]) == nil)
    }

    @Test("A 등급 저장 → B·C 등급이 같은 이름으로 저장하면 그 스케일을 받는다")
    func upsertThenMatch() throws {
        let context = try makeContext()
        let aID = UUID()
        TrueDepthAnchorStore.upsert(personaID: aID, name: "김콜슨", scale: 1.046, in: context)

        #expect(TrueDepthAnchorStore.matchedScale(for: "김콜슨 2", in: context) == 1.046)
        #expect(TrueDepthAnchorStore.matchedScale(for: "다른 사람", in: context) == nil)
    }

    @Test("같은 A 등급 페르소나를 다시 이름 바꿔 저장해도 행이 늘지 않고 갱신된다")
    func upsertIsIdempotentPerPersona() throws {
        let context = try makeContext()
        let aID = UUID()
        TrueDepthAnchorStore.upsert(personaID: aID, name: "김콜슨", scale: 1.0, in: context)
        TrueDepthAnchorStore.upsert(personaID: aID, name: "김콜슨 v2", scale: 1.08, in: context)

        let all = try context.fetch(FetchDescriptor<TrueDepthAnchor>())
        #expect(all.count == 1)
        #expect(all[0].name == "김콜슨 v2")
        #expect(TrueDepthAnchorStore.matchedScale(for: "김콜슨 v2 생일", in: context) == 1.08)
        // 옛 이름("김콜슨")은 더 이상 기준에 없다 — 갱신되었을 뿐 추가되지 않았으므로.
        #expect(TrueDepthAnchorStore.matchedScale(for: "김콜슨 sibling", in: context) == nil)
    }
}
