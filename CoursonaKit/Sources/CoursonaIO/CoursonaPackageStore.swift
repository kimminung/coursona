//
//  CoursonaPackageStore.swift
//  CoursonaIO
//
//  `.coursona` 폴더 패키지 읽기/쓰기 (TechPRD §6.9). zip 은 전송·AirDrop 용으로만(`archive`).
//  UTI `com.coulson.coursona.persona` (Info.plist 에 선언, T-003).
//

import Foundation
import CoursonaCore
import UniformTypeIdentifiers

public struct CoursonaPackage: Sendable {
    public var manifest: CoursonaManifest
    public var identity: Identity
    public var albedo: RGBAImage?
    public var mask: RGBAImage?
    public var thumbnail: RGBAImage?
    public init(manifest: CoursonaManifest, identity: Identity, albedo: RGBAImage?, mask: RGBAImage?, thumbnail: RGBAImage?) {
        self.manifest = manifest; self.identity = identity; self.albedo = albedo; self.mask = mask; self.thumbnail = thumbnail
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
        return CoursonaPackage(manifest: manifest, identity: identity, albedo: img("albedo", "albedo.png"), mask: img("mask", "mask.png"), thumbnail: img("thumb", "thumb.png"))
    }

    public static func readCaptureBundle(from folder: URL) -> CaptureBundle? {
        try? CaptureBundleStore.read(from: folder.appendingPathComponent("capture", isDirectory: true))
    }

    /// 저장된 페르소나 폴더 목록 (최신순, `CaptureBundleStore.list` 와 같은 패턴). 매니페스트만 읽어 빠르다.
    public static func list(in root: URL? = nil) -> [(folder: URL, manifest: CoursonaManifest)] {
        let dir = root ?? defaultRoot
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { folder -> (folder: URL, manifest: CoursonaManifest)? in
            guard let m = try? readManifest(from: folder) else { return nil }
            return (folder, m)
        }
        .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Documents/Personas/
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Personas", isDirectory: true)
    }

    /// 전송·AirDrop 용 zip.
    public static func archive(folder: URL, to url: URL) throws { try ZipArchive.zipFolder(folder).write(to: url) }
    public static func unarchive(_ url: URL, to folder: URL) throws { try ZipArchive.unzip(Data(contentsOf: url), to: folder) }

    /// `archive`/`ShareLink`(AirDrop)·`CoursonaTransfer` 로 받은 `.coursona` zip 하나를 `Documents/Personas/`
    /// 로 들여온다 — 임시 폴더에 풀어 `read`(템플릿 검사 포함)로 한 번 검증한 뒤, 패키지 안의 `manifest.id`
    /// 그대로 `defaultFolder(for:)` 에 쓴다. 같은 페르소나를 다시 받으면(재전송·재내보내기) 새 항목이 느는 대신
    /// 그 자리에서 덮어써진다 — 전송 쪽엔 "이미 들여왔는지" 추적이 없어서(`CoursonaTransfer` 머리말) 멱등하게
    /// 만들어 둔 것. 촬영 원본이 함께 담겨 있었다면 그대로 이어서 들여온다.
    public static func importArchive(from url: URL, expectedTemplate: TemplateManifest? = nil) throws -> CoursonaPackage {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try unarchive(url, to: tmp)
        let pkg = try read(from: tmp, expectedTemplate: expectedTemplate)
        try write(pkg, to: defaultFolder(for: pkg.manifest.id), captureBundle: readCaptureBundle(from: tmp))
        return pkg
    }

    /// Documents/Personas/<uuid>/
    public static func defaultFolder(for id: UUID) -> URL {
        defaultRoot.appendingPathComponent(id.uuidString + ".coursona", isDirectory: true)
    }
}

extension UTType {
    /// 코르소나 패키지. Info.plist 의 `UTExportedTypeDeclarations`/`CFBundleDocumentTypes` 와 일치해야 한다.
    public static var coursonaPersona: UTType {
        UTType(exportedAs: CoursonaPackageStore.uti)
    }
}
