//
//  SaveShareView.swift
//  coursona
//
//  화면 6·6b(UXPRD) — 저장·보내기. 이미 디스크엔 저장돼 있다(`PersonaBuildPipeline` 이 빌드 끝에 바로 쓴다) —
//  여기서는 이름을 바꾸고(최대 20자), 패키지 요약을 보여주고, `.coursona` zip 으로 내보낸다. 6자리 코드
//  기기 간 전송(화면 6b 의 나머지 절반)은 5단계에서 `CoursonaTransfer` 로 연결한다 — 지금은 `ShareLink`
//  (AirDrop·파일 앱 등 시스템 공유 시트) 까지만.
//

import SwiftUI
import CoursonaCore
import CoursonaIO

struct SaveShareView: View {
    @State var package: CoursonaPackage

    @State private var name: String
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var isExporting = false
    @State private var isSaving = false

    init(package: CoursonaPackage) {
        _package = State(initialValue: package)
        _name = State(initialValue: package.manifest.name)
    }

    private var folder: URL { CoursonaPackageStore.defaultFolder(for: package.manifest.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCard

                VStack(alignment: .leading, spacing: 8) {
                    Text("이름").font(.subheadline.weight(.semibold))
                    TextField("코르소나", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { _, new in if new.count > 20 { name = String(new.prefix(20)) } }
                    Text("\(name.count)/20")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                HStack {
                    Image(systemName: package.manifest.includesCaptureBundle ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(package.manifest.includesCaptureBundle ? Color.coursonaSuccess : .secondary)
                    Text("촬영 원본 함께 저장")
                    Spacer()
                }
                .font(.subheadline)
                .padding(.horizontal)

                Button {
                    Task { await saveName() }
                } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text("이름 저장")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(isSaving || name == package.manifest.name)
                .padding(.horizontal)

                shareSection
            }
            .padding(.vertical)
        }
        .background(Color.coursonaBackground)
        .navigationTitle("저장·보내기")
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            TierBadge(tier: package.manifest.tier ?? .b)
            VStack(alignment: .leading, spacing: 4) {
                Text(package.manifest.name).font(.headline)
                Text("\(package.manifest.vertexCount)개 정점 · \(package.manifest.createdOn)")
                    .font(.caption).foregroundStyle(.secondary)
                if let q = package.manifest.textureQuality {
                    Text(String(format: "관측 %.0f%% · 빌드 %.1f초", q.observedRatio * 100, q.buildSeconds))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var shareSection: some View {
        VStack(spacing: 10) {
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(Color.coursonaError)
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("내보내기(AirDrop·파일 앱)", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button { Task { await export() } } label: {
                    HStack(spacing: 8) {
                        if isExporting { ProgressView().controlSize(.small) }
                        Label("내보내기 준비", systemImage: "square.and.arrow.up")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(isExporting)
            }
            Text("기기 간 6자리 코드로 바로 주고받기는 다음 단계에서 연결됩니다.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    private func saveName() async {
        guard name != package.manifest.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        package.manifest.name = name
        try? CoursonaPackageStore.write(package, to: folder)
    }

    private func export() async {
        isExporting = true; exportError = nil
        defer { isExporting = false }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(package.manifest.name).\(CoursonaPackageStore.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            try CoursonaPackageStore.archive(folder: folder, to: url)
            exportURL = url
        } catch {
            exportError = "내보내기 실패: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        SaveShareView(package: CoursonaPackage(manifest: CoursonaManifest(name: "코르소나", createdOn: "Mac", templateID: "t", templateVersion: "1.0", vertexCount: 11569),
                                              identity: Identity.fromTemplate(SyntheticTemplate.make()), albedo: nil, mask: nil, thumbnail: nil))
    }
    .preferredColorScheme(.dark)
}
