//
//  PhotoSuitabilityView.swift
//  coursona
//
//  화면 3(UXPRD) — C등급(사진 1장). 정면·눈 뜸·입 다묾·밝기·얼굴 크기를 B등급과 같은 임계값(`PhotoCaptureGate`)
//  으로 검사한다(`PhotoSuitability`, 순수 로직 — 이미 단위 테스트돼 있음). `PhotoSuitabilityReport` 는
//  "적합 여부 + 실패 이유 목록"만 주므로(항목별 개별 pass/fail이 아님), 실제로 반환하는 정보 그대로
//  보여준다 — 문서에 없는 항목별 체크를 꾸며내지 않는다.
//  "코르소나 만들기"를 누르면 사진 1장을 `CaptureBundle`(sparse, front 1컷)로 바꾼 뒤 화면 4(`BuildProgressView`)
//  로 넘어간다 — 실제 빌드(피팅→텍스처→스플랫→저장)는 거기서 돈다.
//

import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import CoursonaCore
import CoursonaCapture

struct PhotoSuitabilityView: View {
    @State private var session = PhotoCaptureSession()
    @State private var image: CGImage?
    @State private var report: PhotoSuitabilityReport?
    @State private var checking = false
    @State private var picking = false
    @State private var preparing = false
    @State private var prepareError: String?
    @State private var preparedBundle: CaptureBundle?
    @State private var showBuildProgress = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                photoArea
                if let report {
                    suitabilityCard(report)
                }
                if let prepareError {
                    Text(prepareError).font(.caption).foregroundStyle(Color.coursonaError).multilineTextAlignment(.center)
                }
                ctaButton
                Button { picking = true } label: { Label(image == nil ? "사진 선택" : "다른 사진 선택", systemImage: "photo.on.rectangle") }
                    .buttonStyle(.glass)
            }
            .padding()
        }
        .background(Color.coursonaBackground)
        .navigationTitle("사진 1장으로 만들기")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task { await load(url) }
        }
        .navigationDestination(isPresented: $showBuildProgress) {
            if let preparedBundle { BuildProgressView(bundle: preparedBundle, tier: .c) }
        }
    }

    private var photoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(.secondary.opacity(0.1)).aspectRatio(3 / 4, contentMode: .fit)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("정면을 바라보는 밝은 사진 1장을 골라주세요").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if checking { ProgressView().controlSize(.large) }
        }
        .padding(.horizontal)
    }

    private func suitabilityCard(_ report: PhotoSuitabilityReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.isSuitable {
                StatusPill(text: "이 사진으로 만들 수 있어요", kind: .success)
            } else {
                StatusPill(text: "조금만 더 손봐 주세요", kind: .warning)
                ForEach(report.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var ctaButton: some View {
        Button {
            Task { await prepare() }
        } label: {
            if preparing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("사진을 읽는 중…") }
                    .frame(maxWidth: .infinity)
            } else {
                Text("코르소나 만들기(약 30초)").font(.headline).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(image == nil || report?.isSuitable != true || preparing)
        .padding(.horizontal)
    }

    private func load(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return }
        let upright = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: max(cg.width, cg.height, 1)] as CFDictionary) ?? cg
        image = upright
        report = nil
        prepareError = nil
        checking = true
        report = try? await PhotoSuitability.check(upright)
        checking = false
    }

    /// 사진 1장 → sparse `CaptureBundle`(front 1컷). 실제 빌드는 `BuildProgressView` 가 돈다.
    private func prepare() async {
        guard let image else { return }
        preparing = true; prepareError = nil
        defer { preparing = false }
        guard let shot = await session.makeShot(kind: .front, from: image) else {
            prepareError = "얼굴을 찾지 못했습니다 — 다른 사진으로 시도해 주세요"
            return
        }
        preparedBundle = CaptureBundle(meta: session.bundleMeta(shots: [shot.meta]), shots: [shot])
        showBuildProgress = true
    }
}

#Preview {
    NavigationStack { PhotoSuitabilityView() }
        .preferredColorScheme(.dark)
}
