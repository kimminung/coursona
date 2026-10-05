import Testing
import Foundation
@testable import CoursonaCore
@testable import CoursonaIO
@testable import CoursonaValidate

@Suite("검증기 · 클립 · 패키지")
struct ValidatorAndClipTests {
    @Test("합성 템플릿 폴더는 오류 없이 통과한다(LipInner/LidInner·라이브러리·previz 는 경고)")
    func syntheticPasses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try TemplateFolder.writeSynthetic(to: dir)
        let folder = try TemplateFolder(root: dir)
        let issues = TemplateValidator.validate(folder.validationInput())
        let errors = issues.filter { $0.severity == .error }
        #expect(errors.isEmpty, Comment(rawValue: TemplateValidator.report(issues, title: "synthetic")))
        #expect(issues.contains { $0.code == "groups.LipInner" })
        #expect(issues.contains { $0.code == "previz.missing" })
    }

    @Test("깨진 계약은 한국어 수정 문장으로 실패한다")
    func brokenManifestFails() throws {
        var t = SyntheticTemplate.make()
        t.manifest.shapeKeys.removeAll { $0 == "jawOpen" || $0 == "eyeBlinkLeft" }
        t.manifest.groups[VertexGroupName.scalp.rawValue] = []
        t.manifest.boneRest.removeValue(forKey: "Head")
        var clips = SyntheticClips.all().filter { $0.name != "bow" }
        if var idle = clips.first(where: { $0.name == "idle_breathe" }), var tr = idle.shapes["eyeBlinkLeft"] {
            tr[tr.count - 1] = 0.9; idle.shapes["eyeBlinkLeft"] = tr
            clips.removeAll { $0.name == "idle_breathe" }; clips.append(idle)
        }
        let input = ValidationInput(manifest: t.manifest, template: t, clips: clips, previzNames: [], library: [LibraryEntry(name: "hair_bad", kind: .hair, bone: "Head", tintable: true, vertexCount: 1, faceCount: 1), LibraryEntry(name: "Hair_short_crop", kind: .hair, bone: "Head", tintable: true, vertexCount: 1, faceCount: 1)], hasUSDZ: true, hasBustMesh: true)
        let issues = TemplateValidator.validate(input)
        let codes = Set(issues.filter { $0.severity == .error }.map(\.code))
        #expect(codes.contains("shapes.missing"))
        #expect(codes.contains("groups.Scalp"))
        #expect(codes.contains("skeleton.bones"))
        #expect(codes.contains("clips.missing"))
        #expect(codes.contains("clips.seam"))
        #expect(codes.contains("library.names"))
        let msg = issues.first { $0.code == "shapes.missing" }!.message
        #expect(msg.contains("jawOpen") && msg.contains("셰이프키"))
    }

    @Test("절차적 클립이 계약(길이·루프 이음새)을 지키고 보간된다")
    func clips() {
        for spec in SampledClip.contract {
            let c = SyntheticClips.make(spec.name)
            #expect(abs(c.duration - spec.seconds) < 0.05, "\(spec.name)")
            #expect(c.loop == spec.loop)
            if spec.loop { #expect(c.loopSeamError() < 1e-6, "\(spec.name)") }
        }
        let bow = SyntheticClips.make("bow")
        let mid = bow.bonePose(.head, at: bow.duration * 0.45)!
        #expect(mid.rotation.angle > 0.1)   // 숙인 상태
        let end = bow.bonePose(.head, at: bow.duration)!
        #expect(end.rotation.angle < 0.01)  // 복귀
        let w = bow.weights(at: bow.duration * 0.45)
        #expect(w[.eyeLookDownLeft] > 0.7)
        // 루프 클립 시간 랩
        let idle = SyntheticClips.make("idle_breathe")
        #expect(idle.weights(at: 0) == idle.weights(at: idle.duration))
    }

    @Test(".coursona 패키지 쓰기 → 읽기 → 템플릿 불일치 검출")
    func packageRoundTrip() throws {
        let t = SyntheticTemplate.make()
        let id = Identity.fromTemplate(t)
        var manifest = CoursonaManifest(name: "테스트", createdOn: "test", templateID: t.manifest.id, templateVersion: t.manifest.version, vertexCount: t.vertexCount)
        manifest.hair = "Hair_short_crop"
        let albedo = SyntheticAlbedo.image(size: 64)
        let pkg = CoursonaPackage(manifest: manifest, identity: id, albedo: albedo, mask: nil, thumbnail: ImageCodec.thumbnail(albedo, maxDimension: 32))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString).coursona")
        defer { try? FileManager.default.removeItem(at: dir) }
        try CoursonaPackageStore.write(pkg, to: dir)
        let back = try CoursonaPackageStore.read(from: dir, expectedTemplate: t.manifest)
        #expect(back.identity == id)
        #expect(back.manifest.hair == "Hair_short_crop")
        #expect(back.albedo?.width == 64)
        #expect(back.thumbnail?.width == 32)
        var other = t.manifest
        other.version = "9"
        #expect(throws: CoursonaPackageStore.StoreError.self) { try CoursonaPackageStore.read(from: dir, expectedTemplate: other) }
        // zip 왕복
        let zip = dir.deletingPathExtension().appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try CoursonaPackageStore.archive(folder: dir, to: zip)
        let entries = try ZipArchive.read(Data(contentsOf: zip))
        #expect(entries.contains { $0.name == "manifest.json" })
        #expect(entries.contains { $0.name == "identity.bin" })
    }

    @Test("ZIP 64바이트 정렬(usdz 규격)")
    func zipAlignment() throws {
        let data = ZipArchive.make(entries: [ZipEntry(name: "a.usdc", data: Data(repeating: 1, count: 100)), ZipEntry(name: "textures/b.png", data: Data(repeating: 2, count: 10))], alignment: 64)
        let entries = try ZipArchive.read(data)
        #expect(entries.count == 2 && entries[0].data.count == 100)
        // 각 로컬 헤더의 데이터 시작이 64 의 배수
        var off = 0
        for _ in 0..<2 {
            let nameLen = Int(data[off + 26]) | Int(data[off + 27]) << 8
            let extraLen = Int(data[off + 28]) | Int(data[off + 29]) << 8
            let size = Int(data[off + 18]) | Int(data[off + 19]) << 8 | Int(data[off + 20]) << 16 | Int(data[off + 21]) << 24
            let start = off + 30 + nameLen + extraLen
            #expect(start % 64 == 0, "데이터 시작 \(start)")
            off = start + size
        }
    }
}
