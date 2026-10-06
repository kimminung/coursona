//
//  CoursonaPackageStore.swift
//  CoursonaIO
//
//  `.coursona` 폴더 패키지 읽기/쓰기 (TechPRD §6.9). zip 은 전송·AirDrop 용으로만(`archive`).
//  UTI `com.coulson.coursona.persona` (Info.plist 에 선언, T-003).
//

import Foundation
import CoursonaCore
import CoursonaSplat

public struct CoursonaPackage: Sendable {
    public var manifest: CoursonaManifest
    public var identity: Identity
    public var albedo: RGBAImage?
    public var mask: RGBAImage?
    public var thumbnail: RGBAImage?
    /// C8 UI 2단계(T-701 일부) — `splats.bin` 으로 저장·복원된다. nil 이면 스플랫 없이 저장(고스트 폴백만).
    public var splats: [SplatRecord]?
    public init(manifest: CoursonaManifest, identity: Identity, albedo: RGBAImage?, mask: RGBAImage?, thumbnail: RGBAImage?, splats: [SplatRecord]? = nil) {
        self.manifest = manifest; self.identity = identity; self.albedo = albedo; self.mask = mask; self.thumbnail = thumbnail; self.splats = splats
    }
}

public enum CoursonaPackageStore {
    public static let fileExtension = "coursona"
    public static let uti = "com.coulson.coursona.persona"
    public static let captureUTI = "com.coulson.coursona.capture"

    public enum StoreError: Error, LocalizedError {
        case templateMismatch(expected: String, got: String)
        case vertexCountMismatch(expected: Int, got: Int)
        public var errorDescription: String? {
            switch self {
            case .templateMismatch(let e, let g): "템플릿이 다릅니다 (패키지 \(g), 앱 \(e)). 캡처 번들이 있으면 다시 빌드하세요."
            case .vertexCountMismatch(let e, let g): "정점 수가 다릅니다 (패키지 \(g), 템플릿 \(e))."
            }
        }
    }

    public static func write(_ pkg: CoursonaPackage, to folder: URL, captureBundle: CaptureBundle? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = pkg.manifest
        try pkg.identity.serialized().write(to: folder.appendingPathComponent(manifest.files["identity"] ?? "identity.bin"))
        if let a = pkg.albedo { try ImageCodec.png(a).write(to: folder.appendingPathComponent(manifest.files["albedo"] ?? "albedo.png")) }
        if let m = pkg.mask { try ImageCodec.png(m).write(to: folder.appendingPathComponent(manifest.files["mask"] ?? "mask.png")) }
        if let t = pkg.thumbnail { try ImageCodec.png(t).write(to: folder.appendingPathComponent(manifest.files["thumb"] ?? "thumb.png")) }
        if let splats = pkg.splats, !splats.isEmpty {
            try SplatFile.write(splats).write(to: folder.appendingPathComponent("splats.bin"))
            manifest.splatCount = splats.count
        }
        if let cb = captureBundle {
            try CaptureBundleStore.write(cb, to: folder.appendingPathComponent("capture", isDirectory: true))
            manifest.includesCaptureBundle = true
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    public static func readManifest(from folder: URL) throws -> CoursonaManifest {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(CoursonaManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    /// 템플릿 id·버전·정점 수 검사 포함. `expectedTemplate` 가 nil 이면 검사 생략.
    public static func read(from folder: URL, expectedTemplate: TemplateManifest? = nil, loadImages: Bool = true) throws -> CoursonaPackage {
        let manifest = try readManifest(from: folder)
        if let t = expectedTemplate {
            guard manifest.templateID == t.id, manifest.templateVersion == t.version else {
                throw StoreError.templateMismatch(expected: "\(t.id)@\(t.version)", got: "\(manifest.templateID)@\(manifest.templateVersion)")
            }
            guard manifest.vertexCount == t.vertexCount else { throw StoreError.vertexCountMismatch(expected: t.vertexCount, got: manifest.vertexCount) }
        }
        let identity = try Identity(serialized: Data(contentsOf: folder.appendingPathComponent(manifest.files["identity"] ?? "identity.bin")))
        func img(_ key: String, _ def: String) -> RGBAImage? {
            guard loadImages, let d = try? Data(contentsOf: folder.appendingPathComponent(manifest.files[key] ?? def)) else { return nil }
            return try? ImageCodec.decode(d)
        }
        var splats: [SplatRecord]? = nil
        if loadImages, let d = try? Data(contentsOf: folder.appendingPathComponent("splats.bin")) { splats = try? SplatFile.read(d) }
        return CoursonaPackage(manifest: manifest, identity: identity, albedo: img("albedo", "albedo.png"), mask: img("mask", "mask.png"), thumbnail: img("thumb", "thumb.png"), splats: splats)
    }

    public static func readCaptureBundle(from folder: URL) -> CaptureBundle? {
        try? CaptureBundleStore.read(from: folder.appendingPathComponent("capture", isDirectory: true))
    }

    /// 전송·AirDrop 용 zip.
    public static func archive(folder: URL, to url: URL) throws { try ZipArchive.zipFolder(folder).write(to: url) }
    public static func unarchive(_ url: URL, to folder: URL) throws { try ZipArchive.unzip(Data(contentsOf: url), to: folder) }

    /// Documents/Personas/<uuid>/
    public static func defaultFolder(for id: UUID) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Personas", isDirectory: true).appendingPathComponent(id.uuidString + ".coursona", isDirectory: true)
    }
}
