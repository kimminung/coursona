//
//  MirrorView.swift
//  coursona
//
//  화면 6(UXPRD) — 거울(라이브 구동). T-808. 뷰포트 전체가 흉상이고, `FaceDriverCoordinator`(C6)가 매 프레임 가장 좋은
//  입력(iOS Face ID: ARKit 52 표정 + 고개 / Mac·일반 카메라: Vision 12 표정 + 마이크 입모양 / 얼굴 못 찾음: 마이크만)을
//  `FaceRigComponent` 에 넣으면 `FaceRigSystem`(ECS)이 흉상을 움직인다. 흉상 무대(카메라·조명·텍스처·Persona 에셋)는
//  검수 화면과 같은 `PersonaStageHolder`.
//
//  UXPRD 화면 6 요소: 상단 소스 배지("실시간 구동 중 · … · N fps") · 기준 자세 보정 상태 · 안내 토스트("미소를 짓거나 말을
//  해보세요") · 좌하단 PiP 카메라(토글) · 하단 바(카메라/마이크/기준 자세 재설정/공유/닫기) · Vision 경로의 2초
//  캘리브레이션 오버레이(원형 카운트다운 + "건너뛰고 바로 거울 보기") · 얼굴 못 찾음/마이크 꺼짐 상태 문구.
//  정직하게 못 하는 것: PiP 는 Vision 경로만(ARKit 드라이버는 자체 ARSession 이라 프레임을 안 내보낸다 — 배지에 "TrueDepth"
//  라벨만), 지연(ms)은 재지 않는다(카메라 캡처 시각을 모른다 — 구동 루프 fps 만 표시).
//

import SwiftUI
import RealityKit
import CoursonaCore
import CoursonaRig
import CoursonaIO
import CoursonaDrive

struct MirrorView: View {
    let package: CoursonaPackage
    let template: BustTemplate

    @Environment(\.dismiss) private var dismiss
    @State private var stage = PersonaStageHolder()
    @State private var driver = MirrorDriver()
    @State private var showPiP = true
    @State private var showHint = true

    var body: some View {
        ZStack(alignment: .bottom) {
            RealityView { content in
                stage.setup(content: content, template: template, identity: package.identity)
                stage.apply(pose: .zero, gaze: .zero, yaw: 0, motion: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .ignoresSafeArea()

            // 상단: 소스 배지 + 기준 자세 상태 + 등급
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        sourceBadge
                        if driver.coordinator.isTracking, !driver.coordinator.isCalibrating, !driver.coordinator.usesARKit {
                            calibrationDoneBadge
                        }
                    }
                    Spacer()
                    TierBadge(tier: package.manifest.tier ?? .b)
                }
                .padding(12)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // 좌하단 PiP + 안내 토스트
            VStack(alignment: .leading, spacing: 10) {
                if showHint, driver.coordinator.isTracking, !driver.coordinator.isCalibrating {
                    hintToast("미소를 짓거나 말을 해보세요")
                } else if driver.coordinator.cameraEnabled, !driver.coordinator.isTracking, !driver.coordinator.isCalibrating {
                    hintToast("지능형 입모양 보완 — 조명이 어둡거나 얼굴을 찾을 수 없을 때는 마이크 음성 기반 입모양 동기화로 자동 전환됨")
                } else if !driver.coordinator.micEnabled, driver.coordinator.cameraEnabled {
                    hintToast("마이크 꺼짐 — 표정만으로 구동")
                }
                if showPiP { pip }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 92)

            bottomBar

            if driver.coordinator.isCalibrating { calibrationOverlay }
        }
        .background(Color.coursonaBackground)
        .navigationTitle(package.manifest.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await stage.waitForBust()
            await stage.applyTexture(package.albedo)
            stage.setGhostLook(true)
            // 거울은 정면 고정이라 정적 존재 마스크(presence)를 켠다 — 옆·뒤 카드가 비치는 걸 줄인다(AssetContract §5).
            await stage.attachPersonaAssets(package: package, presence: true)
            driver.start(stage: stage)
            // 안내 토스트는 잠깐만.
            try? await Task.sleep(for: .seconds(6))
            showHint = false
        }
        .onDisappear { driver.stop(stage: stage) }
    }

    // MARK: 조각

    private var sourceBadge: some View {
        let c = driver.coordinator
        let running = c.cameraEnabled && (c.isTracking || c.micEnabled)
        let text: String = {
            let fps = driver.fps > 0 ? " · \(driver.fps)fps" : ""
            if !c.cameraEnabled && !c.micEnabled { return "카메라·마이크 꺼짐" }
            let device = c.usesARKit ? "TrueDepth" : "카메라"
            return "\(running ? "실시간 구동 중" : "대기") · \(device) · \(c.source.label)\(fps)"
        }()
        return StatusPill(text: text, kind: running && c.isTracking ? .success : .warning)
    }

    private var calibrationDoneBadge: some View {
        Button {
            driver.coordinator.recalibrate()
        } label: {
            Label("기준 자세 보정 완료 (재설정은 탭)", systemImage: "scope")
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .buttonStyle(.glass)
    }

    private func hintToast(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 360, alignment: .leading)
    }

    /// PiP: Vision 경로의 카메라 프레임(얼굴 추적 랜드마크 점 포함). ARKit 경로는 프레임이 없어 라벨만.
    private var pip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let cg = driver.preview {
                    GeometryReader { geo in
                        ZStack {
                            Image(decorative: cg, scale: 1).resizable().interpolation(.low)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                            Canvas { ctx, size in
                                for p in driver.previewPoints {
                                    let r = CGRect(x: CGFloat(p.x) * size.width - 1, y: (1 - CGFloat(p.y)) * size.height - 1, width: 2, height: 2)
                                    ctx.fill(Path(ellipseIn: r), with: .color(.coursonaSuccess.opacity(0.9)))
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: driver.coordinator.usesARKit ? "faceid" : "video.slash")
                            .font(.title2).foregroundStyle(.secondary)
                        Text(driver.coordinator.usesARKit ? "TrueDepth 추적 중" : "카메라 프레임 없음")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 150, height: 112)
            .background(Color.coursonaSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
            Text(driver.coordinator.usesARKit ? "TrueDepth" : "카메라 피드(얼굴 추적)" + (driver.previewPoints.isEmpty ? "" : " · 랜드마크 \(driver.previewPoints.count)개"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            barToggle("카메라", on: driver.coordinator.cameraEnabled, icon: "video") { driver.coordinator.setCamera(!driver.coordinator.cameraEnabled) }
            barToggle("마이크", on: driver.coordinator.micEnabled, icon: "mic") { driver.coordinator.setMic(!driver.coordinator.micEnabled) }
            barToggle("PiP", on: showPiP, icon: "pip") { showPiP.toggle() }
            Button { driver.coordinator.recalibrate() } label: { Label("기준 자세", systemImage: "scope") }
                .buttonStyle(.glass)
                .disabled(driver.coordinator.usesARKit || !driver.coordinator.cameraEnabled)
            NavigationLink { SaveShareView(package: package) } label: { Label("공유", systemImage: "square.and.arrow.up") }
                .buttonStyle(.glass)
            Button { dismiss() } label: { Label("닫기", systemImage: "xmark") }
                .buttonStyle(.glass)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 16)
    }

    private func barToggle(_ title: String, on: Bool, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: on ? icon : icon + ".slash")
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("\(title) \(on ? "켜짐" : "꺼짐")")
    }

    /// Vision 경로 시작 시 2초 중립 캘리브레이션(UXPRD 화면 6 Mac) — 원형 카운트다운 + 건너뛰기.
    private var calibrationOverlay: some View {
        let tracking = driver.coordinator.isTracking
        let progress = driver.coordinator.calibrationProgress
        return VStack(spacing: 16) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 8).frame(width: 96, height: 96)
                Circle().trim(from: 0, to: progress).stroke(Color.coursonaTierA, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 96, height: 96)
                    .animation(.linear(duration: 0.1), value: progress)
                Text(tracking ? String(format: "%.0f%%", progress * 100) : "얼굴?")
                    .font(.headline.monospacedDigit())
            }
            Text(tracking ? "정면을 보고 2초만 멈춰 주세요" : "카메라 앞에서 정면을 봐 주세요")
                .font(.title3.bold())
            Text("중립 기준 표정과 시선을 보정하고 있습니다")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("건너뛰고 바로 거울 보기") { driver.coordinator.skipCalibration() }
                .buttonStyle(.glass)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
        .transition(.opacity)
    }
}

/// 거울 구동 루프 — 60 Hz 로 `FaceDriverCoordinator.tick` 을 돌려 `FaceRigComponent` 를 채운다(실제 블렌딩은 `FaceRigSystem`).
/// `@Observable` 이라 SwiftUI 가 배지·PiP 를 따라 그린다. PiP 프레임은 매 틱이 아니라 ~15 Hz 로만 갱신(그림 비용).
@MainActor
@Observable
final class MirrorDriver {
    let coordinator = FaceDriverCoordinator()
    private(set) var fps = 0
    private(set) var preview: CGImage?
    private(set) var previewPoints: [SIMD2<Float>] = []
    private var loop: Task<Void, Never>?

    func start(stage: PersonaStageHolder) {
        guard loop == nil, let bust = stage.bust else { return }
        coordinator.start()
        loop = Task { [weak self, weak bust] in
            var frames = 0
            var window = CFAbsoluteTimeGetCurrent()
            var lastPreview = window
            while !Task.isCancelled {
                guard let self, let bust else { break }
                var rig = bust.root.components[FaceRigComponent.self] ?? FaceRigComponent()
                rig.idleMotion = 0          // 고개는 입력이 움직인다 — 절차적 흔들림은 끈다.
                rig.clipWeights = nil
                self.coordinator.tick(rig: &rig, bust: bust)
                bust.root.components.set(rig)
                bust.root.components.set(BustBinding(bust: bust))
                frames += 1
                let now = CFAbsoluteTimeGetCurrent()
                if now - window >= 1 { self.fps = frames; frames = 0; window = now }
                if now - lastPreview >= 1.0 / 15 {
                    lastPreview = now
                    self.preview = self.coordinator.preview
                    self.previewPoints = self.coordinator.previewPoints
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop(stage: PersonaStageHolder) {
        loop?.cancel(); loop = nil
        coordinator.stop()
        fps = 0
        if let bust = stage.bust, var rig = bust.root.components[FaceRigComponent.self] {
            rig.externalWeights = nil; rig.audioLevel = 0
            bust.root.components.set(rig)
            bust.applyHeadPose(nil)
        }
    }
}

#Preview {
    Text("MirrorView 는 실제 CoursonaPackage 가 있어야 미리보기가 됩니다 — 갤러리의 '거울로 보기'로 확인하세요.")
        .padding()
}
