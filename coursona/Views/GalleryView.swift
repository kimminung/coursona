//
//  GalleryView.swift
//  coursona
//
//  화면 3(UXPRD) "갤러리" — 저장된 코르소나 목록. 각 항목을 다시 열어 검수하거나, 함께 저장된 촬영 번들로
//  **다시 캡처하지 않고** 같은 사진으로 다시 빌드할 수 있다(`PersonaBuildPipeline` 재사용, `BuildProgressView`
//  화면 그대로). 번들을 저장 안 한 패키지(`includesCaptureBundle == false`)는 다시 만들기를 숨긴다.
//

import SwiftUI
import CoursonaCore
import CoursonaIO

struct GalleryView: View {
    private struct Entry: Identifiable {
        let folder: URL
        let manifest: CoursonaManifest
        var id: UUID { manifest.id }
    }

    @State private var entries: [Entry] = []
    @State private var errorText: String?
    @State private var busyID: UUID?

    @State private var openPackage: CoursonaPackage?
    @State private var openTemplate: BustTemplate?
    @State private var showInspection = false

    @State private var rebuildBundle: CaptureBundle?
    @State private var rebuildTier: CaptureTier = .b
    @State private var rebuildName = ""
    @State private var showRebuild = false

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("저장된 코르소나가 없어요", systemImage: "square.grid.2x2",
                                           description: Text("스튜디오에서 처음 만들어보세요."))
                } else {
                    List(entries) { entry in row(for: entry) }
                }
            }
            .navigationTitle("갤러리")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { reload() } label: { Image(systemName: "arrow.clockwise") } } }
            .task { reload() }
            .alert("오류", isPresented: .constant(errorText != nil), presenting: errorText) { _ in
                Button("확인") { errorText = nil }
            } message: { Text($0) }
            .navigationDestination(isPresented: $showInspection) {
                if let openPackage, let openTemplate { InspectionView(package: openPackage, template: openTemplate) }
            }
            .navigationDestination(isPresented: $showRebuild) {
                if let rebuildBundle { BuildProgressView(bundle: rebuildBundle, tier: rebuildTier, name: rebuildName) }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.manifest.name).font(.headline)
                Text(entry.manifest.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                if !entry.manifest.includesCaptureBundle {
                    Text("촬영 번들 없음 — 다시 만들기 불가").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busyID == entry.id {
                ProgressView().controlSize(.small)
            } else {
                Button("열기") { open(entry) }.buttonStyle(.glass)
                if entry.manifest.includesCaptureBundle {
                    Button("다시 만들기") { rebuild(entry) }.buttonStyle(.glass)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        entries = CoursonaPackageStore.list().map { Entry(folder: $0.folder, manifest: $0.manifest) }
    }

    private func loadTemplate() throws -> BustTemplate {
        let folder = try TemplateStore.prepareDefault()
        return try TemplateStore.loadTemplate(from: folder)
    }

    private func open(_ entry: Entry) {
        busyID = entry.id
        defer { busyID = nil }
        do {
            let template = try loadTemplate()
            let pkg = try CoursonaPackageStore.read(from: entry.folder, expectedTemplate: template.manifest)
            openTemplate = template
            openPackage = pkg
            showInspection = true
        } catch {
            errorText = "열기 실패: \(error.localizedDescription)"
        }
    }

    private func rebuild(_ entry: Entry) {
        busyID = entry.id
        defer { busyID = nil }
        guard let bundle = CoursonaPackageStore.readCaptureBundle(from: entry.folder) else {
            errorText = "저장된 촬영 번들을 읽지 못했습니다."
            return
        }
        rebuildBundle = bundle
        rebuildTier = entry.manifest.tier ?? .b
        rebuildName = entry.manifest.name
        showRebuild = true
    }
}

#Preview {
    GalleryView()
}
