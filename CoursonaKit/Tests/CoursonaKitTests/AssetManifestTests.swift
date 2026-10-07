import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaIO

@Suite("Persona 에셋 매니페스트 (coursona_assets.json, D-309)")
struct AssetManifestTests {
    /// 블렌더 스크립트(add_hair_long_wave · add_shoulders_shirt · fix_eyes_mouth)가 쓰는 키 그대로 — 설명 문자열·미지 키 포함.
    static let fixture = """
    {
     "schema": "coursona-assets/1",
     "coords": {"blender": "Z-up, 얼굴 −Y", "usd": "Y-up, 얼굴 +Z"},
     "presence": {"face_dir": [0.0, -1.0], "facing_lo": -0.3, "facing_hi": 0.35, "z_lo": 0.06, "z_hi": 0.2, "height_scale": 0.6,
                  "version": "presence/v1", "uv": "CoursonaData (uv1)", "formula": "..."},
     "bust": {"prim": "Bust", "opacity": 0.1, "presence": "앱이 계산", "faceContour": "트루뎁스"},
     "assets": {
      "Hair_long_wave": {
       "prim": "Hair_long_wave", "kind": "hair", "attach": {"mode": "rigid", "bone": "Head", "blender": "BONE"},
       "material": {"opacity": 0.1, "colorless": true, "slots": [{"name": "M_Hair_LongWave", "role": "hair"}]},
       "textures": {"base": "T_Hair_LongWave_base.png", "mask": "T_Hair_LongWave_mask.png"},
       "silhouette": "textures.base alpha", "uvSets": {"UVMap": "uv0", "CoursonaData": "uv1"},
       "vertexCount": 23000, "triangleCount": 11500, "topologyHash": "abc",
       "faceRanges": {"cap": [0, 400], "inner": [[400, 3000], [9000, 9100]], "baby": [11000, 11500]},
       "splatHost": "hosts/SplatHost_Hair_long_wave.json", "splatHostHash": "def",
       "platform": {"iOS": "메시 틀", "macOS": "스플랫"}
      },
      "Shoulders_shirt": {
       "prim": "Shoulders_shirt", "kind": "shoulders", "attach": {"mode": "skin", "joints": ["Root", "Neck"]},
       "material": {"opacity": 0.1, "colorless": true, "slots": [{"name": "M_Shirt_Navy", "role": "cloth"}, {"name": "M_Shirt_Button", "role": "buttons"}]},
       "uvSets": {"UVMap": "u 둘레, v 높이"}, "vertexCount": 5000, "triangleCount": 9800, "topologyHash": "ghi",
       "faceRanges": {"0": [0, 9000], "2": [9000, 9600], "4": [9600, 9800]}, "splatHost": "self(body·collar 구간)"
      },
      "Eye_L": {
       "prim": "Eye_L", "kind": "eye", "attach": {"mode": "rigid", "bone": "Eye_L", "blender": "BONE", "pivot": "오리진 = 눈알 중심"},
       "material": {"opacity": 0.1, "colorless": true, "slots": [{"name": "M_Eye_Sclera", "role": "sclera"}, {"name": "M_Eye_Iris", "role": "iris"}, {"name": "M_Eye_Pupil", "role": "pupil"}]},
       "textures": {"iris": "T_Eye_Iris_base.png", "sclera": "T_Eye_Sclera_base.png"},
       "blendShapes": [], "vertexCount": 2498, "triangleCount": 4992, "allTriangles": true, "topologyHash": null,
       "faceRanges": {"M_Eye_Sclera": [0, 3000], "M_Eye_Iris": [3000, 4500], "M_Eye_Pupil": [4500, 4992]}, "splatHost": null
      }
     }
    }
    """

    @Test("스크립트 키 그대로 디코딩: kind 별 attach, faceRanges [a,b]·[[a,b],…] 혼합, splatHost 문자열/null, 텍스처 없는 셔츠")
    func decodesScriptShapes() throws {
        let m = try JSONDecoder().decode(CoursonaAssetManifest.self, from: Data(Self.fixture.utf8))
        #expect(m.isSupported)
        #expect(m.assets.count == 3)
        #expect(m.bust?.opacity == 0.1)
        let hair = try #require(m.assets["Hair_long_wave"])
        #expect(hair.kind == .hair && hair.attach.isRigid && hair.attach.bone == "Head")
        #expect(hair.textures?["base"] == "T_Hair_LongWave_base.png")
        #expect(hair.faceRanges?["cap"]?.ranges == [0..<400])
        #expect(hair.faceRanges?["inner"]?.ranges == [400..<3000, 9000..<9100])
        #expect(hair.faceRanges?["inner"]?.triangleCount == 2700)
        #expect(hair.splatHost == "hosts/SplatHost_Hair_long_wave.json")
        let shirt = try #require(m.assets["Shoulders_shirt"])
        #expect(shirt.kind == .shoulders && !shirt.attach.isRigid && shirt.attach.joints == ["Root", "Neck"])
        #expect(shirt.textures == nil)
        #expect(shirt.role(forSlot: 0) == "cloth" && shirt.role(forSlot: 1) == "buttons")
        let eye = try #require(m.assets["Eye_L"])
        #expect(eye.kind == .eye && eye.topologyHash == nil && eye.splatHost == nil && eye.blendShapes == [])
        #expect(eye.material.slots.map(\.role) == ["sclera", "iris", "pupil"])
        #expect(m.assets(ofKind: .eye).map(\.prim) == ["Eye_L"])
        // 미지 kind 는 .other 로 떨어진다(디코딩 실패 아님)
        let odd = try JSONDecoder().decode(AssetEntry.self, from: Data(#"{"prim": "X", "kind": "hat", "attach": {"mode": "rigid", "bone": "Head"}}"#.utf8))
        #expect(odd.kind == .other && odd.role(forSlot: 0) == "other")
    }

    @Test("presence 식(AssetContract §5): 정면 1 · 옆 ≈0.44 · 뒤 0 · 가슴 아래 0, height01 은 y/0.6 클램프")
    func presenceFormula() {
        let p = PresenceParams()
        let head = SIMD3<Float>(0, 0.36, 0)
        let c = p.headCenter(headJoint: head)
        #expect(simd_length(c - SIMD3<Float>(0, 0.45, 0)) < 1e-6)
        #expect(abs(p.presence(at: SIMD3(0, 0.45, 0.10), headJoint: head) - 1) < 1e-5)       // 정면
        #expect(p.presence(at: SIMD3(0, 0.45, -0.10), headJoint: head) == 0)                   // 뒤
        let side = p.presence(at: SIMD3(0.10, 0.45, 0), headJoint: head)
        #expect(side > 0.40 && side < 0.48)                                                    // 옆 ≈0.44
        #expect(p.presence(at: SIMD3(0, 0.05, 0.10), headJoint: head) == 0)                    // 가슴 아래(y < z_lo)
        #expect(abs(p.presence(at: SIMD3(0, 0.13, 0.10), headJoint: head) - 0.5) < 0.01)     // z_lo…z_hi 중간
        #expect(p.height01(at: SIMD3(0, 0.30, 0)) == 0.5 && p.height01(at: SIMD3(0, 0.9, 0)) == 1 && p.height01(at: SIMD3(0, -0.1, 0)) == 0)
        // 센터 바로 위(수평 거리 0)는 정면으로 본다
        #expect(abs(p.presence(at: SIMD3(0, 0.6, 0), headJoint: head) - 1) < 1e-5)
    }

    @Test("TemplateStore: 매니페스트가 없으면 nil, 있으면 읽는다 · library.json 은 배열/{items} 둘 다")
    func storeLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TemplateStore.loadAssetManifest(from: dir) == nil)
        #expect(TemplateStore.templateUSDZURL(in: dir) == nil)
        try Data(Self.fixture.utf8).write(to: dir.appendingPathComponent("coursona_assets.json"))
        try Data().write(to: dir.appendingPathComponent("Template.usdz"))
        let m = try #require(TemplateStore.loadAssetManifest(from: dir))
        #expect(m.assets.count == 3)
        #expect(TemplateStore.templateUSDZURL(in: dir) != nil)
        #expect(TemplateStore.texturesFolder(in: dir).lastPathComponent == "textures")
        // 블렌더 add_hair_long_wave 가 쓰는 항목 그대로(materials·textures 만 있고 skinGroups 는 없다) — 선택 키가 빠져도 읽혀야 한다
        let hair = #"{"name": "Hair_long_wave", "kind": "hair", "bone": "Head", "tintable": true, "vertexCount": 1, "faceCount": 1, "materials": ["M_Hair_LongWave"], "textures": {"base": "T_Hair_LongWave_base.png"}}"#
        let shirt = #"{"name": "Shoulders_shirt", "kind": "shoulders", "bone": "Root", "tintable": false, "vertexCount": 2, "faceCount": 2, "skinGroups": ["Root", "Neck"]}"#
        try Data("[\(hair), \(shirt)]".utf8).write(to: dir.appendingPathComponent("library.json"))
        let lib = TemplateStore.loadLibrary(from: dir)
        #expect(lib.map(\.name) == ["Hair_long_wave", "Shoulders_shirt"])
        #expect(lib.first?.textures["base"] == "T_Hair_LongWave_base.png" && lib.first?.skinGroups.isEmpty == true)
        #expect(lib.last?.skinGroups == ["Root", "Neck"] && lib.last?.kind == .shoulders)
        try Data(#"{"items": [\#(hair)]}"#.utf8).write(to: dir.appendingPathComponent("library.json"))
        #expect(TemplateStore.loadLibrary(from: dir).map(\.name) == ["Hair_long_wave"])
    }
}
