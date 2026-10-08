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
        // "내보내기 준비" 를 따로 누르지 않게 화면이 뜨자마자 미리 구워 둔다 — 사용자가 보는 건 바로 에어드랍으로
        // 이어지는 버튼 하나뿐.
        .task { if exportURL == nil { await export() } }
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
                // AirDrop·iCloud 는 공유 시트가 닫힌 뒤에도 이 파일을 다시 읽는다 — 한참 뒤 재시도하거나 전송이
                // 실패했다면 새로 구워서 다시 시도해 볼 수 있게.
                Button { Task { await export() } } label: {
                    HStack(spacing: 6) {
                        if isExporting { ProgressView().controlSize(.small) }
                        Text("전송이 안 되면 다시 만들기")
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isExporting)
            } else {
                // 화면이 뜨자마자 .task 가 export() 를 이미 돌리고 있다 — 여기는 그 준비가 끝나기 전까지만 잠깐 보인다.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("내보내기 준비 중…")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
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
        // 트루뎁스(A 등급) 기준 고정: 내 이름을 저장하면 그 이름 아래 지금 스케일을 기준으로 남기고,
        // Mac·사진(B·C 등급)은 그 이름이 포함된 기준이 있으면 단안 추정 스케일 대신 그 실측 스케일을 쓴다.
        if package.manifest.tier == .a {
            TrueDepthAnchorStore.upsert(personaID: package.manifest.id, name: name, scale: package.identity.scale)
        } else if let scale = TrueDepthAnchorStore.matchedScale(for: name) {
            package.identity.scale = scale
        }
        try? CoursonaPackageStore.write(package, to: folder)
    }

    /// 2026-10-08, 실기기 실측: `FileManager.default.temporaryDirectory` 에 쓴 파일을 `ShareLink` 로 넘기면
    /// AirDrop·"파일 앱에 저장 후 iCloud Drive로 이동" 이 전부 조용히 실패했다(iPhone 16, iOS 27). 두 경로 다
    /// **다른 프로세스(AirDrop 데몬·CloudDocs)가 공유 시트가 끝난 뒤 비동기로 파일을 다시 읽는다** — `tmp/` 는
    /// "쓰는 동안만 보장, 앱이 안 쓰는 동안 시스템이 지울 수 있다"고 문서에 명시돼 있고, 실제로 이 지연된 재접근
    /// 시점에 파일이 이미 없거나 못 읽는 상태였던 것으로 보인다. 고정 위치(Documents)로 옮기고, 화면이 잠겨도
    /// 다른 프로세스가 읽을 수 있게 보호 등급도 명시적으로 낮춘다.
    private var exportsFolder: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func export() async {
        isExporting = true; exportError = nil
        defer { isExporting = false }
        do {
            let url = exportsFolder.appendingPathComponent("\(package.manifest.name).\(CoursonaPackageStore.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            try CoursonaPackageStore.archive(folder: folder, to: url)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
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
