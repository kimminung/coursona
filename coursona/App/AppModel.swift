//
//  AppModel.swift
//  coursona
//
//  앱 상태(@Observable). 초상(Chosang) `App/AppModel.swift` 와 같은 자리·같은 모양(`AppTab` enum +
//  플랫폼별 탭 목록 + 단일 상태 객체)을 그대로 따른다 — 패턴은 검증됐고, 내용만 코르소나 것으로 바꾼다.
//

import Foundation
import Observation
import CoursonaCore
import CoursonaCapture

enum AppTab: String, CaseIterable, Identifiable {
    case studio = "스튜디오"
    case library = "갤러리"
    case inspection = "정밀도"
    case transfer = "기기 연동"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .studio: "person.crop.circle.badge.plus"
        case .library: "square.grid.2x2"
        case .inspection: "checkmark.seal"
        case .transfer: "antenna.radiowaves.left.and.right"
        }
    }

    /// 지금은 세 플랫폼 다 같은 4개 탭(UXPRD §3 — iPhone·iPad 하단 탭 / Mac 상단 탭, 구성은 동일).
    static var platformTabs: [AppTab] { [.studio, .library, .inspection, .transfer] }
}

@MainActor
@Observable
final class AppModel {
    var tab: AppTab = .studio

    /// 화면 1(등급 안내)이 보여줄 추천 등급 — 앱 시작 시 미리 판정해 둔다(TierClassifier). 판정 전엔 nil.
    var detectedTier: CaptureTier?
    var isDetectingTier = false

    init() {}

    /// 한 번 판정하면 다시 하지 않는다 — 시작 화면의 `.task` 는 탭을 오갈 때마다 다시 실행되는데, 같은 기기에서
    /// 결과가 바뀔 일이 없는 하드웨어 검사라 매번 다시 할 이유가 없다(예전엔 매번 TrueDepth 세션을 켜서
    /// 등급 배지가 B↔A 로 흔들리고 UI 가 멈추는 원인이 됐다 — `TierClassifier` 머리말 참고).
    func detectTier() async {
        guard detectedTier == nil, !isDetectingTier else { return }
        isDetectingTier = true
        detectedTier = await TierClassifier.detectAutomaticTier()
        isDetectingTier = false
    }
}
