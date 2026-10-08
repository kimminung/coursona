//
//  TrueDepthAnchorStore.swift
//  CoursonaIO
//
//  이름으로 TrueDepth(A 등급) 절대 스케일을 고정해 두고, 같은 이름이 들어간 이후 Mac·사진(B·C 등급) 빌드에
//  재적용한다 — 단안(Mac 카메라·사진)은 머리 스케일을 추정만 하지만(`Identity.scale` 머리말, "사용자 눈 간격 ÷
//  템플릿 눈 간격"), 한 번 TrueDepth 로 실측한 사람은 그 실측값을 계속 믿는 게 맞다는 요청(2026-10-09)으로
//  추가했다. 바꾸는 건 `scale` 하나뿐 — 피부 텍스처·표정 보정(`patchDeltas`)은 그날그날의 Mac/사진 캡처를
//  그대로 쓴다. `SaveShareView` 가 이름을 저장할 때만 건드린다(빌드 직후 기본 이름 "코르소나" 단계에선 안 함).
//  `CoursonaPackageStore` 의 폴더 스캔과는 별개로, 앱을 껐다 켜도 남는 유일한 인덱스라 SwiftData(기본 디스크
//  저장소)로 둔다 — 디스크 저장소를 못 열면(드문 손상 등) 메모리 전용으로 떨어져 앱이 죽지는 않는다.
//

import Foundation
import SwiftData

@Model
public final class TrueDepthAnchor {
    @Attribute(.unique) public var personaID: UUID
    public var name: String
    public var scale: Float
    public var updatedAt: Date

    public init(personaID: UUID, name: String, scale: Float, updatedAt: Date = .now) {
        self.personaID = personaID; self.name = name; self.scale = scale; self.updatedAt = updatedAt
    }
}

/// `personaID` 당 한 행 — 같은 A 등급 페르소나를 다시 이름 바꿔도 행이 늘지 않고 갱신된다.
@MainActor
public enum TrueDepthAnchorStore {
    private static let container: ModelContainer = {
        let schema = Schema([TrueDepthAnchor.self])
        if let onDisk = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)]) {
            return onDisk
        }
        return (try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
            ?? (try! ModelContainer(for: schema))
    }()

    /// A 등급 페르소나 이름이 (재)저장될 때 호출 — 그 이름 아래 현재 `identity.scale` 을 기준으로 고정한다.
    /// `context` 는 테스트에서 격리된 인메모리 컨텍스트를 주입할 때만 쓰고, 앱에서는 기본값(공유 저장소)을 쓴다.
    public static func upsert(personaID: UUID, name: String, scale: Float, in context: ModelContext? = nil) {
        let context = context ?? container.mainContext
        let existing = try? context.fetch(FetchDescriptor<TrueDepthAnchor>(predicate: #Predicate { $0.personaID == personaID }))
        if let anchor = existing?.first {
            anchor.name = name; anchor.scale = scale; anchor.updatedAt = .now
        } else {
            context.insert(TrueDepthAnchor(personaID: personaID, name: name, scale: scale))
        }
        try? context.save()
    }

    /// B·C 등급 페르소나 이름 저장 시 호출 — 이름이 어떤 기준 이름을 부분 문자열로 포함하면(가장 긴 것 우선,
    /// 짧은 기준 이름이 우연히 끼어드는 오매칭을 줄인다) 그 기준의 스케일을 돌려준다. 없으면 nil(원래 단안
    /// 추정 스케일 그대로 둔다).
    public static func matchedScale(for name: String, in context: ModelContext? = nil) -> Float? {
        let context = context ?? container.mainContext
        guard let anchors = try? context.fetch(FetchDescriptor<TrueDepthAnchor>()) else { return nil }
        let best = bestMatch(for: name, among: anchors.map(\.name))
        return anchors.first { $0.name == best }?.scale
    }

    /// 매칭 규칙만 떼어낸 순수 함수(테스트용) — 비어 있지 않고 부분 문자열로 포함되는 이름 중 가장 긴 것.
    static func bestMatch(for name: String, among anchorNames: [String]) -> String? {
        anchorNames
            .filter { !$0.isEmpty && name.localizedCaseInsensitiveContains($0) }
            .max { $0.count < $1.count }
    }
}
