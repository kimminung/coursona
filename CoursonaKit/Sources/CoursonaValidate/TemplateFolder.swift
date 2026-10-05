//
//  TemplateFolder.swift
//  CoursonaValidate
//
//  `Template/` 폴더(Blender-요청.md §6 산출물) 읽기: template.json · bust.mesh · library.json · clips/*.json · previz/*.mp4 · textures/*.png ·
//  source/ARFaceGeometry.obj(선택, 패치 위치 검사). USDZ 는 RealityKit 이 필요하므로 CoursonaRig 의 로더가 따로 읽어 `usdzPositions` 로 넘긴다.
//

import Foundation
import simd
import CoursonaCore

public struct TemplateFolder: Sendable {
    public var root: URL
    public var manifest: TemplateManifest
    public var bustMesh: BustTemplate?
    public var clips: [SampledClip]
    public var previzNames: Set<String>
    public var library: [LibraryEntry]
    public var textures: Set<String>
    public var objPatchPositions: [SIMD3<Float>]?
    public var hasUSDZ: Bool
    public var hasBustMesh: Bool

    public static let manifestName = "template.json"
    public static let usdzName = "Template.usdz"
    public static let bustMeshName = "bust.mesh"
    public static let libraryName = "library.json"

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        let data = try Data(contentsOf: root.appendingPathComponent(Self.manifestName))
        manifest = try JSONDecoder().decode(TemplateManifest.self, from: data)
        hasUSDZ = fm.fileExists(atPath: root.appendingPathComponent(Self.usdzName).path)
        let meshURL = root.appendingPathComponent(Self.bustMeshName)
        hasBustMesh = fm.fileExists(atPath: meshURL.path)
        bustMesh = hasBustMesh ? try BustMeshFile.read(Data(contentsOf: meshURL), manifest: manifest) : nil
        var clips: [SampledClip] = []
        let clipsDir = root.appendingPathComponent("clips")
        if let names = try? fm.contentsOfDirectory(atPath: clipsDir.path) {
            for n in names.sorted() where n.hasSuffix(".json") {
                if let d = try? Data(contentsOf: clipsDir.appendingPathComponent(n)), let c = try? JSONDecoder().decode(SampledClip.self, from: d) { clips.append(c) }
            }
        }
        self.clips = clips
        let previzDir = root.appendingPathComponent("previz")
        previzNames = Set((try? fm.contentsOfDirectory(atPath: previzDir.path))?.filter { $0.hasSuffix(".mp4") }.map { String($0.dropLast(4)) } ?? [])
        if let d = try? Data(contentsOf: root.appendingPathComponent(Self.libraryName)), let lib = try? JSONDecoder().decode([LibraryEntry].self, from: d) { library = lib } else { library = [] }
        textures = Set((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("textures").path))?.filter { $0.lowercased().hasSuffix(".png") } ?? [])
        objPatchPositions = nil
        let objURL = root.appendingPathComponent("source/ARFaceGeometry.obj")
        if let st = manifest.objToTemplate, let s = st["scale"]?.first, let t = st["translate"], t.count == 3,
           let text = try? String(contentsOf: objURL, encoding: .utf8) {
            var pts: [SIMD3<Float>] = []
            for line in text.split(separator: "\n") where line.hasPrefix("v ") {
                let p = line.split(separator: " ")
                if p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) { pts.append(SIMD3(x, y, z) * s + SIMD3(t[0], t[1], t[2])) }
            }
            if pts.count == ARKitFaceTopology.vertexCount { objPatchPositions = pts }
        }
    }

    public func validationInput(template: BustTemplate? = nil, usdzPositions: [SIMD3<Float>]? = nil, usdzShapeNames: [String]? = nil) -> ValidationInput {
        ValidationInput(manifest: manifest, template: template ?? bustMesh, clips: clips, previzNames: previzNames, library: library, textures: textures,
                        hasUSDZ: hasUSDZ, hasBustMesh: hasBustMesh, objPatchPositions: objPatchPositions, usdzPositions: usdzPositions, usdzShapeNames: usdzShapeNames)
    }

    /// 합성 템플릿으로 Template/ 폴더 쓰기 (검증기 자체 테스트·픽스처).
    public static func writeSynthetic(to root: URL, clips: [SampledClip] = SyntheticClips.all()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("clips"), withIntermediateDirectories: true)
        var t = SyntheticTemplate.make()
        t.manifest.clips = clips.map(\.name)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(t.manifest).write(to: root.appendingPathComponent(manifestName))
        try BustMeshFile.write(t).write(to: root.appendingPathComponent(bustMeshName))
        for c in clips { try enc.encode(c).write(to: root.appendingPathComponent("clips/\(c.name).json")) }
    }
}
