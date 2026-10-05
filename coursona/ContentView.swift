import SwiftUI
import CoursonaCapture

/// T-001 셋업 자리표시자. 실제 화면(시작·등급 안내 등)은 `Docs/UXPRD.md` 화면 1을 따라
/// C8 UI 단계에서 구현한다. 지금은 빌드가 돌아가는지, CoursonaKit 연결과 등급 판정이 동작하는지만 보인다.
struct ContentView: View {
    @State private var tier: CaptureTier?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("코르소나")
                .font(.title.bold())
            Text("C0 셋업 단계 · 이 기기 등급: \(tier?.rawValue.uppercased() ?? "판정 중…")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .task {
            tier = await TierClassifier.detectAutomaticTier()
        }
    }
}

#Preview {
    ContentView()
}
