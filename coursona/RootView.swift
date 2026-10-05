//
//  RootView.swift
//  coursona
//
//  루트: 플랫폼 공통 4탭(스튜디오·갤러리·정밀도·기기 연동, UXPRD §3) — 초상(Chosang) `ContentView.swift`
//  의 `TabView(selection:) { ForEach(AppTab.platformTabs) { Tab(...) { content(for:) } } }` 패턴을
//  그대로 따른다. 갤러리·정밀도·기기 연동은 2~5단계에서 실제 화면으로 채워진다.
//

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            ForEach(AppTab.platformTabs) { tab in
                Tab(tab.rawValue, systemImage: tab.systemImage, value: tab) {
                    content(for: tab)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 640)
        #endif
        // UXPRD §7: 기본 테마는 다크(Liquid Glass Dark) — 라이트 모드에서 글래스 대비가 무너지는 걸 막는다.
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .studio: StartTierView()
        case .library: ComingSoonView(icon: "square.grid.2x2", title: "갤러리", message: "저장된 페르소나 목록은 다음 단계에서 연결됩니다.")
        case .inspection: ComingSoonView(icon: "checkmark.seal", title: "정밀도", message: "검수 화면은 다음 단계에서 연결됩니다.")
        case .transfer: ComingSoonView(icon: "antenna.radiowaves.left.and.right", title: "기기 연동", message: "주고받기 화면은 다음 단계에서 연결됩니다.")
        }
    }
}

#Preview {
    RootView().environment(AppModel())
}
