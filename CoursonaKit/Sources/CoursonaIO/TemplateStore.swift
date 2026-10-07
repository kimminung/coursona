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

    /// 눈알 2개 + 치아·잇몸·혀·입안(`EyesMouth.usdz`, Chosang 과 같은 Blender 내보내기) — 있으면 URL, 없으면 nil
    /// (옛 템플릿 패키지). 로드는 호출자가 `Entity(contentsOf:)` 로(async, RealityKit 의존을 IO 모듈에 안 들인다).
    public static func eyesMouthURL(in folder: URL) -> URL? {
        let url = folder.appendingPathComponent("EyesMouth.usdz")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func loadClips(from folder: URL) -> [SampledClip] {
        let dir = folder.appendingPathComponent("clips")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { n in
            guard n.hasSuffix(".json"), let d = try? Data(contentsOf: dir.appendingPathComponent(n)) else { return nil }
            return try? JSONDecoder().decode(SampledClip.self, from: d)
        }
    }

    /// library.json 최상위는 배열이 기본이지만 블렌더 쪽이 `{items|assets|library|entries: [...]}` 형태를 유지할 수도 있다
    /// (`coursona_common.update_library_json`, Q-D2) — 둘 다 받는다.
    public static func loadLibrary(from folder: URL) -> [LibraryEntry] {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("library.json")) else { return [] }
        if let arr = try? JSONDecoder().decode([LibraryEntry].self, from: d) { return arr }
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        for key in ["items", "assets", "library", "entries"] {
            if let items = obj[key], let data = try? JSONSerialization.data(withJSONObject: items),
               let arr = try? JSONDecoder().decode([LibraryEntry].self, from: data) { return arr }
        }
        return []
    }

    // MARK: Persona 재현 에셋 (Tasks.md D 절, Docs/AssetContract.md)

    /// Template.usdz(Bust + 라이브러리 + 눈·입 메시) — 있으면 URL. 로드는 호출자가 `Entity(contentsOf:)` 로.
    public static func templateUSDZURL(in folder: URL) -> URL? {
        let url = folder.appendingPathComponent("Template.usdz")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `coursona_assets.json`(테크 매니페스트, 앱 로더의 단일 진입점) — 없으면(옛 템플릿) nil.
    public static func loadAssetManifest(from folder: URL) -> CoursonaAssetManifest? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("coursona_assets.json")) else { return nil }
        return try? JSONDecoder().decode(CoursonaAssetManifest.self, from: d)
    }

    public static func texturesFolder(in folder: URL) -> URL { folder.appendingPathComponent("textures", isDirectory: true) }

    /// `library/<name>.usdz` — 초상 내보내기(export_chosang.py)는 라이브러리 오브젝트(Hair_*, Shoulders_* …)를 Template.usdz 에
    /// 넣지 않고 오브젝트마다 따로 낸다. 매니페스트 프림이 Template.usdz 에 없으면 호출자가 여기서 같은 이름을 찾아 함께 로드한다.
    public static func libraryUSDZURL(named name: String, in folder: URL) -> URL? {
        let url = folder.appendingPathComponent("library", isDirectory: true).appendingPathComponent("\(name).usdz")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
