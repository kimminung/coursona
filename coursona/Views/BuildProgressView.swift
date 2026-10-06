//
//  BuildProgressView.swift
//  coursona
//
//  화면 4(UXPRD) — 빌드 진행. `PersonaBuildPipeline`(`CoursonaStudio`, C8 UI 2단계)의 4단계를 체크리스트로
//  보여준다. UXPRD 규칙: 내부 용어("캡" 등)를 화면 문구에 그대로 쓰지 않는다 — "눈과 입 주변을 자연스럽게
//  다듬는 중"처럼 풀어 쓴다. 텍스처 단계 안에서 캡(눈·입)을 닫으므로 UXPRD의 "얼굴면 완성"은 별도 줄이 아니라
//  텍스처 단계 문구에 자연히 녹아 있다(`PersonaBuildStage` 문서 참고).
//

import SwiftUI
import CoursonaCore
import CoursonaIO
import CoursonaStudio
#if DEBUG
import CoursonaTexture
#endif

private enum RowState { case pending, active, done }

struct BuildProgressView: View {
    let bundle: CaptureBundle
    let tier: CaptureTier
    var name: String = "코르소나"

    @State private var template: BustTemplate?
    @State private var stage: PersonaBuildStage = .fitting
    @State private var stageFraction: Double = 0
    @State private var package: CoursonaPackage?
    @State private var errorText: String?
    @State private var buildTask: Task<Void, Never>?
    @State private var showInspection = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 18) {
                ForEach(PersonaBuildStage.allCases, id: \.self) { s in
                    StageRow(title: title(for: s), state: rowState(s), fraction: s == stage ? stageFraction : 1)
                }
            }
            .padding(.horizontal, 32)

            if let errorText {
                VStack(spacing: 12) {
                    Text(errorText).font(.subheadline).foregroundStyle(Color.coursonaError).multilineTextAlignment(.center)
                    Button("다시 시도") { start() }.buttonStyle(.glass)
                }
                .padding(.horizontal, 32)
            }
            Spacer()
            if errorText == nil && package == nil {
                Button("취소") { cancel() }.buttonStyle(.glass)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.coursonaBackground)
        .navigationTitle("만드는 중")
        .navigationBarBackButtonHidden(package == nil && errorText == nil)
        .task { start() }
        .onDisappear { buildTask?.cancel() }
        .navigationDestination(isPresented: $showInspection) {
            if let package, let template { InspectionView(package: package, template: template) }
        }
    }

    private func title(for s: PersonaBuildStage) -> String {
        switch s {
        case .fitting: "얼굴 형태를 맞추는 중"
        case .texture: "눈과 입 주변을 자연스럽게 다듬고 색을 입히는 중"
        case .splat: "입체감을 더하는 중"
        case .package: "저장하는 중"
        }
    }

    private func rowState(_ s: PersonaBuildStage) -> RowState {
        if package != nil { return .done }
        let all = PersonaBuildStage.allCases
        guard let si = all.firstIndex(of: s), let ci = all.firstIndex(of: stage) else { return .pending }
        if si < ci { return .done }
        if si == ci { return .active }
        return .pending
    }

    private func start() {
        buildTask?.cancel()
        errorText = nil
        package = nil
        stage = .fitting
        stageFraction = 0
        buildTask = Task {
            do {
                let folder = try TemplateStore.prepareDefault()
                let t = try TemplateStore.loadTemplate(from: folder)
                guard !Task.isCancelled else { return }
                template = t
                let pkg = try await PersonaBuildPipeline.run(bundle: bundle, template: t, tier: tier, name: name) { p in
                    Task { @MainActor in
                        stage = p.stage
                        stageFraction = p.fraction
                    }
                }
                guard !Task.isCancelled else { return }
                package = pkg
                showInspection = true
            } catch {
                guard !Task.isCancelled else { return }
                errorText = "만들기 실패: \(error.localizedDescription)"
            }
        }
    }

    private func cancel() {
        buildTask?.cancel()
    }
}

private struct StageRow: View {
    let title: String
    let state: RowState
    let fraction: Double

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(state == .active ? .semibold : .regular))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                if state == .active {
                    ProgressView(value: fraction).tint(Color.coursonaTierA)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Circle().stroke(.secondary.opacity(0.4), lineWidth: 2).frame(width: 22, height: 22)
        case .active:
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.coursonaSuccess).frame(width: 22, height: 22)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        BuildProgressView(bundle: SyntheticCapture.makeBundle(template: SyntheticTemplate.make()), tier: .a)
    }
    .preferredColorScheme(.dark)
}
#endif
