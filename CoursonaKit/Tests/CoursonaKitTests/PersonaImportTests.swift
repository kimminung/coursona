import Testing
import Foundation
@testable import CoursonaCore
@testable import CoursonaIO

/// 전송·AirDrop 으로 받은 `.coursona` 를 갤러리 폴더로 들여오는 길(`CoursonaPackageStore.importArchive`,
/// 2026-10-09) — 전에는 `ReceivedStore` 가 원본 바이트만 내려놓고 아무도 갤러리로 옮기지 않았다.
@Suite("패키지 가져오기 (전송·AirDrop)")
struct PersonaImportTests {
    @Test("zip 으로 내보낸 패키지를 다시 들여오면 같은 id·이름·스케일로 갤러리 폴더에 나타난다")
    func importArchiveRoundTrips() throws {
        let template = SyntheticTemplate.make()
        var identity = Identity.fromTemplate(template)
        identity.scale = 1.046
        let manifest = CoursonaManifest(name: "김콜슨", createdOn: "iPhone", templateID: template.manifest.id,
                                        templateVersion: template.manifest.version, vertexCount: template.manifest.vertexCount)
        let pkg = CoursonaPackage(manifest: manifest, identity: identity, albedo: nil, mask: nil, thumbnail: nil)

        let sourceFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).coursona")
        defer {
            try? FileManager.default.removeItem(at: sourceFolder)
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: CoursonaPackageStore.defaultFolder(for: manifest.id))
        }
        try CoursonaPackageStore.write(pkg, to: sourceFolder)
        try CoursonaPackageStore.archive(folder: sourceFolder, to: zipURL)

        let imported = try CoursonaPackageStore.importArchive(from: zipURL, expectedTemplate: template.manifest)
        #expect(imported.manifest.id == manifest.id)
        #expect(imported.manifest.name == "김콜슨")
        #expect(imported.identity.scale == 1.046)

        // 갤러리가 보는 자리(`list()`)에 실제로 나타나야 한다 — 임시 폴더에만 풀리고 끝나면 안 된다.
        let reread = try CoursonaPackageStore.read(from: CoursonaPackageStore.defaultFolder(for: manifest.id))
        #expect(reread.manifest.id == manifest.id)
    }

    @Test("다른 템플릿으로 받은 패키지는 템플릿 불일치로 거절된다")
    func importRejectsTemplateMismatch() throws {
        let template = SyntheticTemplate.make()
        let identity = Identity.fromTemplate(template)
        let manifest = CoursonaManifest(name: "다른 템플릿", createdOn: "iPhone", templateID: "other-template",
                                        templateVersion: "9.9", vertexCount: template.manifest.vertexCount)
        let pkg = CoursonaPackage(manifest: manifest, identity: identity, albedo: nil, mask: nil, thumbnail: nil)

        let sourceFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).coursona")
        defer {
            try? FileManager.default.removeItem(at: sourceFolder)
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: CoursonaPackageStore.defaultFolder(for: manifest.id))
        }
        try CoursonaPackageStore.write(pkg, to: sourceFolder)
        try CoursonaPackageStore.archive(folder: sourceFolder, to: zipURL)

        #expect(throws: (any Error).self) {
            try CoursonaPackageStore.importArchive(from: zipURL, expectedTemplate: template.manifest)
        }
        // 거절됐으니 갤러리 폴더엔 아무것도 남지 않아야 한다.
        #expect(!FileManager.default.fileExists(atPath: CoursonaPackageStore.defaultFolder(for: manifest.id).path))
    }
}
