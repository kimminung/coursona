//
//  CaptureBundleStore.swift
//  CoursonaIO
//
//  캡처 번들 폴더 읽기/쓰기 + `.coursonacapture`(stored zip). 포맷은 CoursonaCore/Formats.md.
//  캡처 데이터는 저장소에 커밋하지 않는다 — Fixtures 에는 합성 번들만.
//

import Foundation
import CoursonaCore

public enum CaptureBundleStore {
    public static let metaName = "meta.json"
    public static let fileExtension = "coursonacapture"
    /// 썸네일 긴 변 (T-204). 5컷 × 약 10 KB 이라 번들 크기에 영향이 없다.
    public static let thumbnailMaxDimension = 256

    public static func write(_ bundle: CaptureBundle, to folder: URL, jpegQuality: Double = 0.92) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = bundle.meta
        meta.shots = []
        for shot in bundle.shots {
            var m = shot.meta
            if let img = shot.image {
                try ImageCodec.jpeg(img, quality: jpegQuality).write(to: folder.appendingPathComponent(m.imageFile))
                m.imageWidth = img.width; m.imageHeight = img.height
                let thumb = shot.thumbnail ?? ImageCodec.thumbnail(img, maxDimension: thumbnailMaxDimension)
                let name = m.thumbFile ?? "thumb-\(m.kind.rawValue).jpg"
                try ImageCodec.jpeg(thumb, quality: 0.8).write(to: folder.appendingPathComponent(name))
                m.thumbFile = name
            }
            if let d = shot.depth {
                let name = m.depthFile ?? "depth-\(meta.shots.count).f32"
                m.depthFile = name
                m.depthWidth = d.width; m.depthHeight = d.height
                try d.values.withUnsafeBytes { Data($0) }.write(to: folder.appendingPathComponent(name))
            }
            meta.shots.append(m)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: folder.appendingPathComponent(metaName))
    }

    /// 번들 읽기. `loadImages == false` 면 원본 JPEG 를 건너뛰고 **썸네일만** 읽는다(목록 화면용, T-204).
    public static func read(from folder: URL, loadImages: Bool = true) throws -> CaptureBundle {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let meta = try dec.decode(CaptureBundleMeta.self, from: Data(contentsOf: folder.appendingPathComponent(metaName)))
        var shots: [CaptureShot] = []
        for m in meta.shots {
            var image: RGBAImage? = nil
            if loadImages, let data = try? Data(contentsOf: folder.appendingPathComponent(m.imageFile)) {
                image = try? ImageCodec.decode(data)
            }
            var thumb: RGBAImage? = nil
            if let tf = m.thumbFile, let data = try? Data(contentsOf: folder.appendingPathComponent(tf)) {
                thumb = try? ImageCodec.decode(data)
            } else if let image {
                thumb = ImageCodec.thumbnail(image, maxDimension: thumbnailMaxDimension)
            }
            var depth: DepthMap? = nil
            if let df = m.depthFile, let w = m.depthWidth, let h = m.depthHeight,
               let data = try? Data(contentsOf: folder.appendingPathComponent(df)), data.count == w * h * 4 {
                let vals = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                depth = DepthMap(width: w, height: h, values: vals)
            }
            shots.append(CaptureShot(meta: m, image: image, depth: depth, thumbnail: thumb))
        }
        return CaptureBundle(meta: meta, shots: shots)
    }

    /// 저장된 캡처 폴더 목록 (최신순). 메타만 읽어 빠르다.
    public static func list(in root: URL? = nil) -> [CaptureBundleMeta] {
        let dir = root ?? defaultRoot
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return items.compactMap { folder -> CaptureBundleMeta? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(metaName)) else { return nil }
            return try? dec.decode(CaptureBundleMeta.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// `.coursonacapture` 로 묶기.
    public static func archive(_ bundle: CaptureBundle, to url: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("coursona-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(bundle, to: tmp)
        try ZipArchive.zipFolder(tmp).write(to: url)
    }

    /// `.coursonacapture` 풀어서 읽기.
    public static func readArchive(_ url: URL, loadImages: Bool = true) throws -> CaptureBundle {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("coursona-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ZipArchive.unzip(Data(contentsOf: url), to: tmp)
        return try read(from: tmp, loadImages: loadImages)
    }

    /// 기본 보관 위치 Documents/Captures/
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures", isDirectory: true)
    }
    /// 기본 보관 위치 Documents/Captures/<uuid>/
    public static func defaultFolder(for id: UUID) -> URL {
        defaultRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
