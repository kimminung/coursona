import SwiftUI
import CoursonaCapture

/// T-001 셋업 자리표시자. 실제 화면(시작·등급 안내 등)은 `Docs/UXPRD.md` 화면 1을 따라
/// C8 UI 단계에서 구현한다. 지금은 빌드가 돌아가는지, CoursonaKit 연결과 등급 판정이 동작하는지만 보인다.
///
/// T-307 실기기 조사 결론: 등급 판정이 라이브 미리보기·안내 없이 조용히 진행되면, 사용자가 그 사이 카메라를
/// 보고 있지 않아(안내가 없으니 당연하다) TrueDepth 기기도 B 로 잘못 보일 수 있다 — 여기서는 C8 전체 캡처
/// 화면을 당겨오지 않고, 그 결론이 요구한 최소한("카메라를 봐주세요" 안내)만 먼저 넣는다.
/// 2026-10-06 추가 확인: 안내를 넣은 뒤에도 또 B 가 나와 실기기 콘솔 로그로 들여다보니, 카메라는 바로 켜지고
/// 얼굴도 0.5초 안에 잡히는데 `capturedDepthData` 가 붙은 프레임 자체가 평균 ≈0.86초 간격으로 드물게 온다는
/// 걸 확인했다 — `TierClassifier.detectAutomaticTier` 의 `depthTimeout` 을 2.0 → 5.0 초로 올려 해결(실기기로
/// 연속 2회 A 확인). 자세한 측정값은 그 파일 머리말 참고.
struct ContentView: View {
    @State private var tier: CaptureTier?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("코르소나")
                .font(.title.bold())
            if tier == nil {
                Text("카메라를 봐주세요…")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
            }
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
