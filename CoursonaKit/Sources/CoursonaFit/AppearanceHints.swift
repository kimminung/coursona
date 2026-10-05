//
//  AppearanceHints.swift
//  CoursonaFit
//
//  소반 7차 `Persona/AppearanceHints.swift` 이식 + 확장(TechPRD §6.6): 머리 길이·볼륨·앞머리·묶음·안경·수염·어깨 옷.
//  좌표·형상은 절대 모델에 맡기지 않는다. 결과는 `Hair_<id>`/`Glasses_<id>`/`Beard_<id>`/`Shoulders_<id>` 선택의 초기값일 뿐이다.
//  FoundationModels(사진 Attachment) 는 OS 27 부터. 그 전/시뮬레이터/시간 초과(8 s) 는 색 기반 휴리스틱.
//

import Foundation
import CoreGraphics
import simd
import CoursonaCore
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct AppearanceHints: Codable, Hashable, Sendable {
    public enum HairLength: String, Codable, Sendable, CaseIterable { case buzz, short, medium, long }
    public enum Level: String, Codable, Sendable, CaseIterable { case low, medium, high }
    public enum Beard: String, Codable, Sendable, CaseIterable { case none, stubble, short }
    public enum Garment: String, Codable, Sendable, CaseIterable { case tee, shirt }

    public var hairLength: HairLength = .medium
    public var hairVolume: Level = .medium
    public var hasBangs = false
    public var isTied = false
    public var wearsGlasses = false
    public var beard: Beard = .none
    public var garment: Garment = .tee
    /// "FoundationModels" / "heuristic"
    public var source: String = "heuristic"

    public init() {}

    /// 라이브러리 이름 선택 (Blender-요청.md §4 목록).
    public var hairLibraryID: String {
        switch (hairLength, isTied, hasBangs, hairVolume) {
        case (.buzz, _, _, _): return "Hair_buzz"
        case (.short, _, true, _): return "Hair_bangs_short"
        case (.short, _, false, .low): return "Hair_short_crop"
        case (.short, _, false, _): return "Hair_short_side"
        case (.medium, true, _, _): return "Hair_tied_low"
        case (.medium, _, true, _): return "Hair_bangs_medium"
        case (.medium, _, false, _): return "Hair_medium_wave"
        case (.long, true, _, _): return "Hair_tied_high"
        case (.long, _, true, _): return "Hair_bangs_long"
        case (.long, _, false, .high): return "Hair_long_wave"
        case (.long, _, false, _): return "Hair_long_straight"
        }
    }
    public var glassesLibraryID: String? { wearsGlasses ? "Glasses_thin" : nil }
    public var beardLibraryID: String? { beard == .none ? nil : "Beard_\(beard.rawValue)" }
    public var shouldersLibraryID: String { "Shoulders_\(garment.rawValue)" }

    public var summary: String {
        var parts: [String] = []
        switch hairLength { case .buzz: parts.append("아주 짧은 머리"); case .short: parts.append("짧은 머리"); case .medium: parts.append("중간 머리"); case .long: parts.append("긴 머리") }
        parts.append(hairVolume == .high ? "볼륨 큼" : (hairVolume == .low ? "볼륨 작음" : "볼륨 보통"))
        if hasBangs { parts.append("앞머리") }
        if isTied { parts.append("묶음") }
        if wearsGlasses { parts.append("안경") }
        if beard != .none { parts.append(beard == .stubble ? "수염 자국" : "짧은 수염") }
        parts.append(garment == .shirt ? "셔츠" : "티셔츠")
        return parts.joined(separator: " · ") + (source == "FoundationModels" ? " (Apple Intelligence)" : " (휴리스틱)")
    }

    public var record: AppearanceHintsRecord {
        var r = AppearanceHintsRecord()
        r.hairLength = hairLength.rawValue; r.hairVolume = hairVolume.rawValue; r.hasBangs = hasBangs; r.isTied = isTied
        r.wearsGlasses = wearsGlasses; r.beard = beard.rawValue; r.shoulderGarment = garment.rawValue; r.source = source
        return r
    }
}

/// 휴리스틱 입력: 정면 사진의 정규화 좌표(0…1, 원점 좌상단) 랜드마크. Vision 또는 ARKit 투영에서 만든다.
public struct AppearanceInput: Sendable {
    public var faceBox: CGRect
    public var browLineV: CGFloat
    public var skin: SIMD3<Float>
    public init(faceBox: CGRect, browLineV: CGFloat, skin: SIMD3<Float>) { self.faceBox = faceBox; self.browLineV = browLineV; self.skin = skin }
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, visionOS 26, *)
@Generable
struct AppearanceReport {
    @Generable enum HairLength { case buzz, short, medium, long }
    @Generable enum Level { case low, medium, high }
    @Generable enum Beard { case none, stubble, short }
    @Generable enum Garment { case tee, shirt }

    @Guide(description: "Hair length: buzz (shaved), short (above ears), medium (to the jaw), long (past the shoulders)")
    var hairLength: HairLength
    @Guide(description: "How voluminous or thick the hair looks")
    var hairVolume: Level
    @Guide(description: "True if bangs or fringe cover part of the forehead")
    var hasBangs: Bool
    @Guide(description: "True if the hair is tied back (ponytail, bun)")
    var isTied: Bool
    @Guide(description: "True if the person wears eyeglasses")
    var wearsGlasses: Bool
    @Guide(description: "Facial hair: none, stubble, or short beard")
    var beard: Beard
    @Guide(description: "Upper-body garment: tee (round neck, no collar) or shirt (collar)")
    var garment: Garment
}
#endif

/// 외형 힌트 분석기. 메인 액터에서 호출(FoundationModels 세션).
@MainActor
public enum AppearanceAnalyzer {
    public static func analyze(image: CGImage, input: AppearanceInput?) async -> AppearanceHints {
        if let hints = await analyzeWithFoundationModels(image: image) { return hints }
        return heuristic(image: image, input: input)
    }

    public static var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, visionOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    #if canImport(FoundationModels)
    /// 사진 첨부(`Attachment`)는 OS 27 부터.
    @available(iOS 27, macOS 27, visionOS 27, *)
    private static func respondWithImage(_ small: CGImage) async throws -> AppearanceHints {
        let session = LanguageModelSession(instructions: """
        You describe only coarse visual attributes of a person in a photo so an app can pick a matching cartoon hairstyle. \
        Do not identify the person. Answer with the requested fields only.
        """)
        let response = try await session.respond(generating: AppearanceReport.self) {
            "Look at this photo of a person and fill in the appearance fields."
            Attachment(small)
        }
        let r = response.content
        var h = AppearanceHints()
        h.hairLength = switch r.hairLength { case .buzz: .buzz; case .short: .short; case .medium: .medium; case .long: .long }
        h.hairVolume = switch r.hairVolume { case .low: .low; case .medium: .medium; case .high: .high }
        h.hasBangs = r.hasBangs; h.isTied = r.isTied; h.wearsGlasses = r.wearsGlasses
        h.beard = switch r.beard { case .none: .none; case .stubble: .stubble; case .short: .short }
        h.garment = switch r.garment { case .tee: .tee; case .shirt: .shirt }
        h.source = "FoundationModels"
        return h
    }
    #endif

    private static func analyzeWithFoundationModels(image: CGImage) async -> AppearanceHints? {
        #if canImport(FoundationModels)
        guard isModelAvailable else { return nil }
        guard #available(iOS 27, macOS 27, visionOS 27, *) else { return nil }
        let small = ImageSampler.downscale(image, maxDimension: 512) ?? image
        let work = Task<AppearanceHints?, Never> { try? await respondWithImage(small) }
        let timeout = Task<AppearanceHints?, Never> {
            try? await Task.sleep(for: .seconds(8))
            return nil
        }
        let result = await withTaskGroup(of: AppearanceHints?.self, returning: AppearanceHints?.self) { group in
            group.addTask { await work.value }
            group.addTask { await timeout.value }
            let first = await group.next() ?? nil
            if first == nil, let second = await group.next() ?? nil { return second }
            group.cancelAll()
            work.cancel(); timeout.cancel()
            return first
        }
        return result
        #else
        return nil
        #endif
    }

    /// 색 기반 휴리스틱 (모델 없을 때). 머리카락 = 피부색과 먼 어두운 색.
    nonisolated public static func heuristic(image: CGImage, input: AppearanceInput?) -> AppearanceHints {
        var h = AppearanceHints()
        h.source = "heuristic"
        guard let input, let s = ImageSampler(cgImage: image, maxDimension: 256) else { return h }
        let fb = input.faceBox
        let skin = input.skin
        func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(a - b) / 1.732 }
        func hairLike(_ c: SIMD3<Float>?) -> Bool { guard let c else { return false }; return dist(c, skin) > 0.22 && (c.x + c.y + c.z) / 3 < 0.5 }
        let chinY = fb.maxY
        let sideL = CGRect(x: fb.minX - fb.width * 0.25, y: chinY + fb.height * 0.1, width: fb.width * 0.2, height: fb.height * 0.25)
        let sideR = CGRect(x: fb.maxX + fb.width * 0.05, y: chinY + fb.height * 0.1, width: fb.width * 0.2, height: fb.height * 0.25)
        let longHair = hairLike(s.average(in: sideL)) || hairLike(s.average(in: sideR))
        let jawL = CGRect(x: fb.minX - fb.width * 0.22, y: fb.minY + fb.height * 0.55, width: fb.width * 0.18, height: fb.height * 0.3)
        let mediumHair = hairLike(s.average(in: jawL))
        let crown = CGRect(x: fb.midX - fb.width * 0.2, y: fb.minY - fb.height * 0.25, width: fb.width * 0.4, height: fb.height * 0.12)
        let crownHair = hairLike(s.average(in: crown))
        h.hairLength = longHair ? .long : (mediumHair ? .medium : (crownHair ? .short : .buzz))
        let forehead = CGRect(x: fb.midX - fb.width * 0.15, y: input.browLineV - fb.height * 0.16, width: fb.width * 0.3, height: fb.height * 0.1)
        h.hasBangs = hairLike(s.average(in: forehead))
        // 볼륨: 머리 위쪽 머리카락 폭 / 얼굴 폭
        let topRow = max(0, fb.minY - fb.height * 0.15)
        if let span = s.darkSpan(atV: topRow, skin: skin) {
            let ratio = span / Float(fb.width)
            h.hairVolume = ratio > 1.3 ? .high : (ratio < 0.95 ? .low : .medium)
        }
        // 수염: 턱 아래 피부가 어두우면
        let chin = CGRect(x: fb.midX - fb.width * 0.15, y: fb.minY + fb.height * 0.82, width: fb.width * 0.3, height: fb.height * 0.1)
        if let c = s.average(in: chin) {
            let d = dist(c, skin)
            h.beard = d > 0.25 ? .short : (d > 0.12 ? .stubble : .none)
        }
        // 옷: 어깨 영역 밝기 대비 (셔츠 깃 = 밝은 띠) — 거칠다; 기본 tee
        h.garment = .tee
        return h
    }
}

/// CGImage → 작은 RGBA 래스터 샘플러 (CoreGraphics 만).
public struct ImageSampler: Sendable {
    public let width: Int, height: Int
    public let bytes: [UInt8]

    public init?(cgImage: CGImage, maxDimension: Int) {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(cgImage.width, cgImage.height)))
        let w = max(1, Int(CGFloat(cgImage.width) * scale)), h = max(1, Int(CGFloat(cgImage.height) * scale))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; bytes = buf
    }

    /// 정규화 사각형(0…1, 원점 좌상단) 평균색 (0…1). 영역이 비면 nil.
    public func average(in r: CGRect) -> SIMD3<Float>? {
        let x0 = max(0, Int(r.minX * CGFloat(width))), x1 = min(width - 1, Int(r.maxX * CGFloat(width)))
        let y0 = max(0, Int(r.minY * CGFloat(height))), y1 = min(height - 1, Int(r.maxY * CGFloat(height)))
        guard x1 >= x0, y1 >= y0 else { return nil }
        var sum = SIMD3<Float>.zero; var n = 0
        for y in y0...y1 { for x in x0...x1 {
            let i = (y * width + x) * 4
            if bytes[i + 3] > 40 { sum += SIMD3(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255; n += 1 }
        } }
        return n > 0 ? sum / Float(n) : nil
    }

    /// 주어진 높이(정규화 v)에서 어두운(머리카락 같은) 픽셀의 가로 범위 (정규화 폭).
    public func darkSpan(atV v: CGFloat, skin: SIMD3<Float>) -> Float? {
        let y = min(height - 1, max(0, Int(v * CGFloat(height))))
        var minX = Int.max, maxX = Int.min
        for x in 0..<width {
            let i = (y * width + x) * 4
            let c = SIMD3(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255
            if bytes[i + 3] > 40, simd_length(c - skin) / 1.732 > 0.22, (c.x + c.y + c.z) / 3 < 0.5 { minX = min(minX, x); maxX = max(maxX, x) }
        }
        return minX <= maxX ? Float(maxX - minX) / Float(width) : nil
    }

    public static func downscale(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
