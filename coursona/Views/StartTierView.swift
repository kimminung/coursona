//
//  StartTierView.swift
//  coursona
//
//  화면 1(UXPRD) — 등급 3가지 중 하나를 고르는 시작 화면. 동등한 카드 3장 + 추천 리본 + 개인정보 한 줄.
//  UXPRD §4 원칙: B·C 를 "열등한" 등급으로 말하지 않는다 — 각 카드는 "지금 바로"/"더 정밀하게"/"가장 빠르게"
//  같은 긍정 문구만 쓴다. 2단계: 실제 캡처 화면(`CaptureGuideView`/`PhotoSuitabilityView`)으로 연결한다.
//  Face ID 카메라(A)는 iPhone·iPad 전용이라 Mac에서는 안내만 하고 캡처로 들어가지 않는다.
//

import SwiftUI
import CoursonaCore
import CoursonaCapture

private struct TierOption: Identifiable {
    let id: CaptureTier
    let title: String
    let subtitle: String
    let systemImage: String
    let estimate: String
}

private let tierOptions: [TierOption] = [
    TierOption(id: .a, title: "Face ID 카메라로 만들기", subtitle: "얼굴 형태·깊이를 직접 측정",
              systemImage: "faceid", estimate: "약 2분"),
    TierOption(id: .b, title: "이 기기 카메라로 만들기", subtitle: "얼굴 치수는 추정, 나중에 업그레이드 가능",
              systemImage: "camera.fill", estimate: "약 2분"),
    TierOption(id: .c, title: "사진 1장으로 만들기", subtitle: "정면만 측정, 옆모습은 추정",
              systemImage: "photo.fill", estimate: "약 30초"),
]

struct StartTierView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    VStack(spacing: 14) {
                        ForEach(tierOptions) { option in
                            NavigationLink {
                                destination(for: option.id)
                            } label: {
                                TierCard(option: option, recommended: model.detectedTier == option.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)

                    Text("모든 처리는 기기 안에서만 이뤄집니다 — 사진·영상은 서버로 전송되지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                }
                .padding(.vertical, 24)
            }
            .background(Color.coursonaBackground)
            .navigationTitle("코르소나")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        PermissionsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .task { await model.detectTier() }
    }

    @ViewBuilder
    private func destination(for tier: CaptureTier) -> some View {
        switch tier {
        case .a:
            #if os(iOS)
            CaptureGuideView(source: FaceCaptureSession(), tier: .a)
            #else
            ComingSoonView(icon: "faceid", title: "Face ID 카메라로 만들기", message: "Face ID 카메라는 iPhone·iPad(Face ID 모델)에서만 쓸 수 있습니다.")
            #endif
        case .b:
            CaptureGuideView(source: PhotoCaptureSession(), tier: .b)
        case .c:
            PhotoSuitabilityView()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            if model.isDetectingTier {
                // 등급 확인은 보통 눈 깜짝할 새 끝나지만(카메라를 켜지 않는 하드웨어 조회 한 번), 기기가 막 켜져
                // 미디어 서비스가 아직 안 깨어 있으면 눈에 띄게 걸릴 수 있다 — 고정 아이콘만 있으면 "멈췄나?"
                // 싶을 수 있어 실행 중임을 또렷이 보여주는 스피너로 바꾼다(실기기 탭 전환 중 렉 관찰, 2026-10-06).
                ProgressView()
                    .controlSize(.large)
                    .frame(height: 40)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            if model.isDetectingTier {
                Text("이 기기에 맞는 방법을 확인하는 중…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let tier = model.detectedTier {
                Text("이 기기는 \(tier.badgeLabel)등급을 지원합니다 — 아래에서 "+tier.shortPitch+" 만들 수 있어요")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

private struct TierCard: View {
    let option: TierOption
    let recommended: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: option.systemImage)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(option.id.badgeColor.opacity(0.18), in: .circle)
                .foregroundStyle(option.id.badgeColor)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.title).font(.headline)
                    TierBadge(tier: option.id)
                    if recommended {
                        Text("추천")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.coursonaSuccess.opacity(0.2), in: .capsule)
                            .foregroundStyle(Color.coursonaSuccess)
                    }
                }
                Text(option.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(option.estimate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

#Preview {
    StartTierView().environment(AppModel())
        .preferredColorScheme(.dark)
}
