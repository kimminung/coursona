//
//  CaptureGuideView.swift
//  coursona
//
//  화면 2(UXPRD) — A/B 등급 공용 캡처 가이드. 초상(Chosang) `Views/GuidedCaptureView.swift`(538줄)를 포팅했다 —
//  전체 화면 카메라 미리보기 + 단계 칩(촬영분은 썸네일) + 각도 링(게이트 유지 진행률) + 조도 배너 + 셔터.
//  게이트가 유지되면 자동 촬영(`CaptureGuide`), 수동 셔터·건너뛰기·칩 탭 재촬영은 그대로.
//
//  코르소나에서 바뀐 것: 초상은 iOS(ARKit)·Mac(사진 폴백)을 **다른 화면**(`GuidedCaptureView`/`PhotoCaptureView`)
//  으로 나눴지만, UXPRD 화면 2는 "A/B 공용 뼈대"로 정의해서 여기선 한 화면을 iOS·macOS 둘 다에서 쓴다 — 햅틱만
//  `#if os(iOS)` 로 가린다. `ShotKind` 가 7개(눈 감기·입 벌림 선택 2컷 포함)라 칩·아이콘·안내문을 그만큼 늘렸다.
//  완료되면 초상의 "번들 저장+내보내기" 대신 `BuildProgressView`(화면 4, C8 UI 3단계)로 넘어가 거기서
//  `CoursonaStudio.PersonaBuildPipeline` 을 끝까지(피팅→텍스처→스플랫→패키지 저장) 돌린다.
//

import SwiftUI
import simd
import UniformTypeIdentifiers
import ImageIO
import CoursonaCore
import CoursonaCapture
import CoursonaIO
#if os(iOS)
import UIKit
#endif

/// 가이드 화면이 소스에 요구하는 것 (ARKit · 사진 폴백 공용) — 초상과 같은 추상화.
@MainActor
protocol GuidedCaptureSource: AnyObject, Observable {
    var modeTitle: String { get }
    var isSparse: Bool { get }
    var cameraAvailable: Bool { get }
    var isRunning: Bool { get }
    var errorText: String? { get }
    var isTracked: Bool { get }
    var yaw: Float { get }
    var pitch: Float { get }
    var previewImage: CGImage? { get }
    var previewPoints: [SIMD2<Float>] { get }
    var holdSeconds: Double { get }
    var angleTolerance: (yaw: Float, pitch: Float) { get }
    var lightWarning: String? { get }
    var summaryLine: String { get }
    var diagnostics: String { get }
    func start()
    func stop()
    func passesGate(for kind: ShotKind) -> (ok: Bool, reason: String)
    func captureShot(kind: ShotKind) -> CaptureShot?
    func importShot(kind: ShotKind, image: CGImage) async -> CaptureShot?
    var supportsImport: Bool { get }
    func bundleMeta(shots: [CaptureShotMeta]) -> CaptureBundleMeta
}

struct CaptureGuideView<Source: GuidedCaptureSource>: View {
    @State private var source: Source
    let tier: CaptureTier
    @State private var guide: CaptureGuide
    @State private var speech = SpeechGuide()
    @State private var shots: [CaptureShot] = []
    @State private var thumbs: [ShotKind: CGImage] = [:]
    @State private var message = ""
    @State private var showDiagnostics = false
    @State private var importing = false
    @State private var mirror = false
    @State private var voice = false
    @State private var flash = false

    @State private var showBuildProgress = false

    init(source: Source, tier: CaptureTier) {
        _source = State(initialValue: source)
        self.tier = tier
        _guide = State(initialValue: CaptureGuide(holdSeconds: source.holdSeconds))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraLayer.ignoresSafeArea()
            if flash { Color.white.ignoresSafeArea().transition(.opacity) }
            VStack(spacing: 8) {
                stepStrip.padding(.top, 8)
                if let w = source.lightWarning, source.isRunning {
                    Label(w, systemImage: "sun.max.trianglebadge.exclamationmark")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .glassEffect(.regular.tint(.orange.opacity(0.18)))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if source.isRunning || !shots.isEmpty { guidance }
                Spacer()
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center).lineLimit(2)
                        .padding(.horizontal, 12).padding(.vertical, 6).glassEffect()
                }
                bottomBar.padding(.bottom, 8)
            }
            .padding(.horizontal, 16)
            .animation(.easeInOut(duration: 0.25), value: source.lightWarning)
            if !source.isRunning && shots.isEmpty { startCard }
        }
        .task(id: source.isRunning) { await tickLoop() }
        .onChange(of: voice) { _, on in speech.isEnabled = on; if on { speech.say(guide.current.map(hint) ?? "", interrupt: true) } }
        .onDisappear { source.stop(); speech.stop() }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, let kind = guide.current else { return }
            Task { await importPhoto(url, kind: kind) }
        }
        .navigationDestination(isPresented: $showBuildProgress) {
            BuildProgressView(bundle: CaptureBundle(meta: source.bundleMeta(shots: shots.map(\.meta)), shots: shots), tier: tier)
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 600)
        #endif
    }

    // MARK: 카메라 + 오버레이

    private var cameraLayer: some View {
        GeometryReader { geo in
            if let cg = source.previewImage {
                let fitted = fill(CGSize(width: cg.width, height: cg.height), in: geo.size)
                ZStack {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.low)
                        .frame(width: fitted.width, height: fitted.height).position(x: fitted.midX, y: fitted.midY)
                    Canvas { ctx, _ in
                        let sx = fitted.width / CGFloat(cg.width), sy = fitted.height / CGFloat(cg.height)
                        for p in source.previewPoints {
                            let q = CGPoint(x: fitted.minX + CGFloat(p.x) * sx, y: fitted.minY + CGFloat(p.y) * sy)
                            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 1.2, y: q.y - 1.2, width: 2.4, height: 2.4)), with: .color(.white.opacity(0.5)))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .scaleEffect(x: mirror ? -1 : 1, y: 1)
            }
        }
    }

    private func fill(_ img: CGSize, in box: CGSize) -> CGRect {
        guard img.width > 0, img.height > 0 else { return .zero }
        let s = max(box.width / img.width, box.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    // MARK: 단계 칩 (촬영분은 썸네일)

    private var stepStrip: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(guide.steps, id: \.self) { kind in
                    let st = guide.state(of: kind)
                    Button { retake(kind) } label: {
                        VStack(spacing: 2) {
                            if let t = thumbs[kind] {
                                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.green, lineWidth: 1.5))
                            } else {
                                Image(systemName: icon(for: kind, state: st)).font(.body.weight(.semibold)).frame(height: 30)
                            }
                            Text(shortTitle(kind)).font(.caption2)
                        }
                        .frame(width: 58, height: 52)
                        .foregroundStyle(st == .current ? Color.accentColor : (st == .captured ? .green : .white.opacity(st == .skipped ? 0.5 : 0.85)))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(st == .current ? .regular.tint(.accentColor.opacity(0.25)) : .regular, in: .rect(cornerRadius: 14))
                    .accessibilityLabel("\(kind.title) \(st == .captured ? "촬영됨, 다시 찍기" : (st == .skipped ? "건너뜀" : (st == .current ? "현재" : "대기")))")
                }
            }
        }
    }

    private func icon(for kind: ShotKind, state: CaptureGuide.StepState) -> String {
        if state == .captured { return "checkmark.circle.fill" }
        if state == .skipped { return "minus.circle" }
        switch kind {
        case .front: return "face.smiling"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .up: return "arrow.up.circle"
        case .smile: return "face.smiling.inverse"
        case .eyesClosed: return "eye.slash"
        case .mouthOpen: return "mouth"
        }
    }

    private func shortTitle(_ k: ShotKind) -> String {
        switch k {
        case .front: "정면"; case .left: "왼쪽"; case .right: "오른쪽"; case .up: "위"; case .smile: "미소"
        case .eyesClosed: "눈 감기"; case .mouthOpen: "입 벌림"
        }
    }

    private func hint(_ k: ShotKind) -> String {
        switch k {
        case .front: "카메라를 똑바로 보고 표정을 풀어 주세요"
        case .left: "고개를 내 왼쪽으로 30° — 오른쪽 뺨이 카메라를 향하게"
        case .right: "고개를 내 오른쪽으로 30° — 왼쪽 뺨이 카메라를 향하게"
        case .up: "턱을 15° 들어 주세요"
        case .smile: "카메라를 보고 활짝 웃어 주세요"
        case .eyesClosed: "눈을 편하게 감아 주세요(선택)"
        case .mouthOpen: "입을 자연스럽게 벌려 주세요(선택)"
        }
    }

    // MARK: 각도 링 + 안내

    private var guidance: some View {
        VStack(spacing: 14) {
            if let kind = guide.current {
                angleRing(for: kind)
                let gate = source.passesGate(for: kind)
                Text(kind.title).font(.title3.bold()).foregroundStyle(.white)
                Text(source.isTracked ? gate.reason : "얼굴을 찾는 중").font(.headline).foregroundStyle(gate.ok ? .green : .white)
                    .padding(.horizontal, 14).padding(.vertical, 8).glassEffect()
                    .contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: gate.reason)
                Text(hint(kind)).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            } else {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("\(guide.completedCount)컷 완료").font(.title2.bold()).foregroundStyle(.white)
                Text("코르소나 만들기를 누르면 피팅·텍스처·입체감까지 한 번에 만듭니다").font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            }
            if let e = source.errorText { Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
        }
    }

    private func angleRing(for kind: ShotKind) -> some View {
        let (ty, tp) = kind.targetYawPitch
        let maxDeg: Float = 25
        let R: CGFloat = 54
        let dx = CGFloat(max(-1, min(1, (source.yaw - ty) / maxDeg))) * R * (mirror ? -1 : 1)
        let dy = CGFloat(max(-1, min(1, -(source.pitch - tp) / maxDeg))) * R
        let ok = source.passesGate(for: kind).ok
        let tol = source.angleTolerance
        let zoneW = CGFloat(min(1, tol.yaw / maxDeg)) * R * 2, zoneH = CGFloat(min(1, tol.pitch / maxDeg)) * R * 2
        return ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: 2).frame(width: R * 2, height: R * 2)
            Ellipse().fill((ok ? Color.green : Color.white).opacity(0.12)).frame(width: zoneW, height: zoneH)
            Ellipse().stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(width: zoneW, height: zoneH)
            Circle().trim(from: 0, to: guide.holdProgress).stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: R * 2 + 10, height: R * 2 + 10)
                .animation(.linear(duration: 0.1), value: guide.holdProgress)
            Circle().fill(ok ? Color.green : (source.isTracked ? Color.yellow : Color.gray))
                .frame(width: 18, height: 18).offset(x: dx, y: dy)
                .animation(.easeOut(duration: 0.12), value: dx + dy)
        }
        .frame(height: R * 2 + 16)
        .accessibilityHidden(true)
    }

    // MARK: 하단 바

    private var bottomBar: some View {
        HStack {
            Button { skip() } label: { Label("건너뛰기", systemImage: "forward.end").labelStyle(.iconOnly).font(.title3) }
                .buttonStyle(.glass).disabled(guide.isComplete || !source.isRunning)
                .accessibilityLabel("이 컷 건너뛰기")
            Spacer()
            if guide.isComplete {
                Button { source.stop(); showBuildProgress = true } label: {
                    Label("코르소나 만들기", systemImage: "wand.and.stars").font(.headline).padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
            } else {
                shutter
            }
            Spacer()
            Button { showDiagnostics = true } label: { Image(systemName: "info.circle").font(.title3) }
                .buttonStyle(.glass)
                .accessibilityLabel("진단")
        }
    }

    private var shutter: some View {
        let kind = guide.current
        let ready = kind.map { source.passesGate(for: $0).ok } ?? false
        return Button { if let kind { capture(kind) } } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(ready ? Color.green : Color.white).frame(width: 62, height: 62)
            }
        }
        .buttonStyle(.plain)
        .disabled(!source.isRunning || !source.isTracked)
        .opacity(source.isRunning && source.isTracked ? 1 : 0.5)
        .accessibilityLabel(kind.map { "\($0.title) 촬영" } ?? "촬영")
    }

    // MARK: 시작 카드

    private var startCard: some View {
        VStack(spacing: 16) {
            Image(systemName: source.isSparse ? "camera.viewfinder" : "faceid").font(.system(size: 48)).foregroundStyle(.white)
            Text("내 흉상 만들기").font(.title.bold()).foregroundStyle(.white)
            Text("정면·왼쪽 30°·오른쪽 30°·위 15°·미소 다섯 컷(+ 선택 2컷)을 안내에 따라 찍습니다. 점이 점선 안에 들어오면 \(String(format: "%.1f", source.holdSeconds))초 뒤 자동으로 촬영됩니다.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
            Text(source.modeTitle).font(.caption).foregroundStyle(.white.opacity(0.7))
            if source.cameraAvailable {
                Button { source.start() } label: { Text("시작").font(.headline).frame(maxWidth: 220) }.buttonStyle(.glassProminent).controlSize(.large)
            } else {
                Text("이 기기에는 얼굴 추적 카메라가 없습니다. 사진 파일로 컷을 채울 수 있습니다.").font(.caption).foregroundStyle(.yellow).multilineTextAlignment(.center)
            }
            if source.supportsImport {
                Button { importing = true } label: { Label("사진 불러오기 (\(guide.current?.title ?? "완료"))", systemImage: "photo.on.rectangle") }
                    .buttonStyle(.glass).disabled(guide.isComplete)
            }
            if let e = source.errorText { Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
        }
        .padding(24)
        .glassEffect(in: .rect(cornerRadius: 24))
        .padding(24)
    }

    // MARK: 진단 시트

    private var diagnosticsSheet: some View {
        NavigationStack {
            List {
                Section("모드") {
                    Text(source.modeTitle)
                    Text(source.summaryLine).font(.caption.monospacedDigit())
                    Toggle("거울 미리보기", isOn: $mirror)
                    Toggle("음성 안내 (한국어)", isOn: $voice)
                }
                Section("프로브 · 원값") {
                    Text(source.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                }
                if !shots.isEmpty {
                    Section("찍은 컷 \(shots.count)") {
                        ForEach(shots, id: \.kind) { s in
                            let m = s.meta
                            HStack(spacing: 10) {
                                if let t = thumbs[m.kind] {
                                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.kind.title).font(.headline)
                                    Text("\(m.imageWidth)×\(m.imageHeight) · 깊이 \(s.depth.map { "\($0.width)×\($0.height)" } ?? "없음") · 정점 \(m.faceVertexArray.count) · 랜드마크 \(m.landmarkArray.count) · 평균 \(m.averagedFrames) 프레임")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if source.supportsImport {
                    Section { Button("사진 불러오기 (\(guide.current?.title ?? "완료"))") { showDiagnostics = false; importing = true }.disabled(guide.isComplete) }
                }
            }
            .navigationTitle("진단")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { showDiagnostics = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 동작

    private func tickLoop() async {
        guard source.isRunning else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard source.isRunning, let kind = guide.current else { continue }
            let gate = source.passesGate(for: kind)
            let ok = source.isTracked && gate.ok
            if voice { speech.say(source.isTracked ? (gate.ok ? "" : gate.reason) : "얼굴을 찾는 중입니다") }
            if guide.update(gateOK: ok, now: Date().timeIntervalSince1970) { capture(kind, auto: true) }
        }
    }

    private func capture(_ kind: ShotKind, auto: Bool = false) {
        guard let shot = source.captureShot(kind: kind) else { message = "프레임이 없습니다"; return }
        store(shot)
        guide.markCaptured(kind)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        speech.resetRepeatGuard()
        if voice { speech.say(guide.current.map { "\($0.title). " + hint($0) } ?? "다 찍었습니다", interrupt: true) }
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        Task { try? await Task.sleep(for: .milliseconds(90)); withAnimation(.easeIn(duration: 0.15)) { flash = false } }
    }

    private func store(_ shot: CaptureShot) {
        var shot = shot
        if let img = shot.image {
            let t = ImageCodec.thumbnail(img, maxDimension: CaptureBundleStore.thumbnailMaxDimension)
            shot.thumbnail = t
            thumbs[shot.kind] = ImageCodec.cgImage(t)
        }
        shots.removeAll { $0.kind == shot.kind }
        shots.append(shot)
        let m = shot.meta
        message = "\(m.kind.title) 촬영 — \(m.imageWidth)×\(m.imageHeight)" + (shot.depth != nil ? " · 깊이 O" : "") + (m.isSparse ? " · 랜드마크 \(m.landmarkArray.count)" : " · 정점 \(m.faceVertexArray.count)")
    }

    private func skip() {
        guide.skip()
        speech.resetRepeatGuard()
        if voice, let k = guide.current { speech.say("\(k.title). " + hint(k), interrupt: true) }
    }

    private func retake(_ kind: ShotKind) {
        guide.retake(kind)
        thumbs[kind] = nil
        shots.removeAll { $0.kind == kind }
        speech.resetRepeatGuard()
        if !source.isRunning, source.cameraAvailable { source.start() }
    }

    private func importPhoto(_ url: URL, kind: ShotKind) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { message = "이미지를 열 수 없습니다: \(url.lastPathComponent)"; return }
        let upright = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: max(cg.width, cg.height, 1)] as CFDictionary) ?? cg
        if let shot = await source.importShot(kind: kind, image: upright) { store(shot); guide.markCaptured(kind) }
        else { message = "얼굴을 찾지 못했습니다: \(url.lastPathComponent)" }
    }
}

// MARK: - 소스 어댑터

#if os(iOS)
extension FaceCaptureSession: GuidedCaptureSource {
    var modeTitle: String { "TrueDepth · ARKit 얼굴 메시 1220점 + 깊이" }
    var isSparse: Bool { false }
    var cameraAvailable: Bool { FaceCaptureSession.isSupported }
    var isTracked: Bool { status.isTracked }
    var yaw: Float { status.yaw }
    var pitch: Float { status.pitch }
    var previewImage: CGImage? { preview }
    var holdSeconds: Double { gate.holdSeconds }
    var angleTolerance: (yaw: Float, pitch: Float) { (gate.yawTolerance, gate.pitchTolerance) }
    var summaryLine: String {
        let s = status
        return String(format: "yaw %.1f° · pitch %.1f° · 중립도 %.2f · %.0f lm · 깊이 %@", s.yaw, s.pitch, s.neutrality, s.ambientLumens, s.hasDepth ? "O" : "X")
    }
    var diagnostics: String {
        let top = topShapes.isEmpty ? "중립" : topShapes.map { String(format: "%@ %.2f", $0.0.rawValue, $0.1) }.joined(separator: " · ")
        return "중립도 기여: \(top)\n\n" + (probe?.summary ?? "세션을 시작하면 첫 프레임에서 프로브가 기록됩니다.")
    }
    func importShot(kind: ShotKind, image: CGImage) async -> CaptureShot? { nil }
    var supportsImport: Bool { false }
    func bundleMeta(shots: [CaptureShotMeta]) -> CaptureBundleMeta {
        CaptureBundleMeta(device: UIDevice.current.model, sparse: false, arkitTriangleHash: probe?.triangleHash, arkitVertexCount: probe?.vertexCount ?? 0, shots: shots)
    }
}
#endif

extension PhotoCaptureSession: GuidedCaptureSource {
    var modeTitle: String { "사진 폴백 · Vision 76점 (TrueDepth 없음, sparse)" }
    var isSparse: Bool { true }
    var cameraAvailable: Bool { PhotoCaptureSession.hasCamera }
    var isTracked: Bool { status.isTracked }
    var yaw: Float { status.yaw }
    var pitch: Float { status.pitch }
    var previewImage: CGImage? { preview }
    var previewPoints: [SIMD2<Float>] { previewLandmarks }
    var holdSeconds: Double { gate.holdSeconds }
    var angleTolerance: (yaw: Float, pitch: Float) { (gate.yawTolerance, gate.pitchTolerance) }
    var summaryLine: String {
        let s = status
        return String(format: "yaw %.1f° · pitch %.1f° · roll %.1f° · 밝기 %.2f · 얼굴 폭 %.0f %% · %d×%d", s.yaw, s.pitch, s.roll, s.brightness, s.faceWidthRatio * 100, s.imageWidth, s.imageHeight)
    }
    var diagnostics: String {
        let s = status
        return String(format: "Vision 원값 yaw %.1f° pitch %.1f° · 랜드마크 %d · 카메라 %@\n수평 FOV %.0f° (%@) · IPD 가정 %.0f mm", s.visionYaw, s.visionPitch, s.landmarkCount, cameraName, assumedHorizontalFOV, fovIsMeasured ? "센서" : "가정", SparseFaceGeometry.assumedInterpupillary * 1000)
    }
    func importShot(kind: ShotKind, image: CGImage) async -> CaptureShot? { await makeShot(kind: kind, from: image) }
    var supportsImport: Bool { true }
    func bundleMeta(shots: [CaptureShotMeta]) -> CaptureBundleMeta {
        CaptureBundleMeta(device: PhotoCaptureSession.deviceDescription, sparse: true, arkitTriangleHash: nil, arkitVertexCount: 0, shots: shots)
    }
}
