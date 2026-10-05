//
//  TemplateStore.swift
//  CoursonaIO
//
//  기본 템플릿 패키지(`Default.coursonatemplate` = Template 폴더의 stored zip: template.json · bust.mesh · Template.usdz · library.json · clips/ · textures/)
//  를 앱 번들에서 1회 풀어 캐시(T-104 "1회 캐시, 버전 해시"). 캐시 키 = zip 크기 + template.json 의 id@version.
//  라이브러리 USDZ(library/*.usdz, 146 MB)는 번들에 넣지 않는다(M5 에서 온디맨드/압축 결정).
//

import Foundation
import CoursonaCore

public enum TemplateStore {
    public static let bundleResourceName = "Default"
    public static let bundleResourceExtension = "coursonatemplate"

    public enum StoreError: Error, LocalizedError {
        case missingResource
        case badArchive
        public var errorDescription: String? {
            switch self {
            case .missingResource: "번들에 Default.coursonatemplate 이 없습니다 (tools/make_default_template.sh 로 만듭니다)"
            case .badArchive: "템플릿 패키지를 풀 수 없습니다"
            }
        }
    }

    /// 캐시 루트: Application Support/Coursona/Templates/
    public static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coursona/Templates", isDirectory: true)
    }

    /// 번들 zip → 캐시 폴더 (이미 풀려 있고 크기 표식이 같으면 그대로). 반환 = template.json 이 있는 폴더.
    public static func prepareDefault(bundle: Bundle = .main) throws -> URL {
        guard let zip = bundle.url(forResource: bundleResourceName, withExtension: bundleResourceExtension) else { throw StoreError.missingResource }
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        let dir = cacheRoot.appendingPathComponent("default-\(size)", isDirectory: true)
        let stamp = dir.appendingPathComponent(".ok")
        if FileManager.default.fileExists(atPath: stamp.path), FileManager.default.fileExists(atPath: dir.appendingPathComponent("template.json").path) {
            return dir
        }
        try? FileManager.default.removeItem(at: dir)
        try ZipArchive.unzip(Data(contentsOf: zip), to: dir)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("template.json").path) else { throw StoreError.badArchive }
        try Data().write(to: stamp)
        // 오래된 캐시 정리
        if let others = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) {
            for u in others where u.lastPathComponent.hasPrefix("default-") && u.lastPathComponent != dir.lastPathComponent { try? FileManager.default.removeItem(at: u) }
        }
        return dir
    }

    /// 폴더에서 BustTemplate 읽기 (template.json + bust.mesh).
    public static func loadTemplate(from folder: URL) throws -> BustTemplate {
        let manifest = try JSONDecoder().decode(TemplateManifest.self, from: Data(contentsOf: folder.appendingPathComponent("template.json")))
        return try BustMeshFile.read(Data(contentsOf: folder.appendingPathComponent("bust.mesh")), manifest: manifest)
    }

    public static func loadClips(from folder: URL) -> [SampledClip] {
        let dir = folder.appendingPathComponent("clips")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { n in
            guard n.hasSuffix(".json"), let d = try? Data(contentsOf: dir.appendingPathComponent(n)) else { return nil }
            return try? JSONDecoder().decode(SampledClip.self, from: d)
        }
    }

    public static func loadLibrary(from folder: URL) -> [LibraryEntry] {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("library.json")) else { return [] }
        return (try? JSONDecoder().decode([LibraryEntry].self, from: d)) ?? []
    }
}
