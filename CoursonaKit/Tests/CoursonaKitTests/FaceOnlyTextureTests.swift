import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaTexture

/// C5 T-501: `TextureBuildOptions.faceOnly` — 얼굴 밖은 전체 해상도 투영을 건너뛰고(기존 채움 로직이 메운다),
/// 대신 저해상도 스플랫 색 한 장을 낸다.
@Suite("faceOnly 텍스처 프리셋 (C5, T-501)")
struct FaceOnlyTextureTests {
    static let template = SyntheticTemplate.make()

    static func bundle() -> CaptureBundle {
        var o = SyntheticCaptureOptions()
        o.imageWidth = 640; o.imageHeight = 480; o.depthWidth = 320; o.depthHeight = 240
        return SyntheticCapture.makeBundle(template: template, options: o) { u, v in SyntheticAlbedo.smooth(u: u, v: v) }
    }

    @Test("기본값(faceOnly 꺼짐)은 splatColor 가 nil — 기존 동작 안 건드림")
    func defaultHasNoSplatColor() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var o = TextureBuildOptions(); o.size = 128; o.supersample = 1
        let r = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: o)
        #expect(r.splatColor == nil)
    }

    @Test("faceOnlyPreset: splatColor 가 지정한 크기로 나오고, 내용이 비어있지 않다")
    func faceOnlyProducesSplatColor() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        let o = TextureBuildOptions.faceOnlyPreset(size: 128, splatColorSize: 64)
        let r = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: o)
        let splat = try #require(r.splatColor)
        #expect(splat.width == 64 && splat.height == 64)
        var nonEmpty = 0
        for y in 0..<splat.height { for x in 0..<splat.width where splat[x, y].w > 0 { nonEmpty += 1 } }
        #expect(nonEmpty > 100, "스플랫 색 텍셀이 거의 비어 있음(\(nonEmpty))")
    }

    @Test("faceOnly 는 얼굴 밖을 건너뛰어 '관측' 대신 '채움' 비율이 는다")
    func faceOnlySkipsNonFaceAccumulation() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var full = TextureBuildOptions(); full.size = 256; full.supersample = 1
        let rFull = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: full)
        let rFace = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: .faceOnlyPreset(size: 256, splatColorSize: 64))
        // 단계별 시간은 이 크기(256, 0.x 초)에서 측정 잡음이 커서(머신 부하에 따라 2배씩 흔들림) 여기선 비교하지 않는다 —
        // 실제 속도 이득은 2k/4k·🧪 실기기에서 재는 게 맞다(T-505). 여기선 "덜 보고 더 채운다" 는 결과만 확인한다.
        print("전체: 관측 \(rFull.quality.observedRatio) 채움 \(rFull.quality.filledRatio) · faceOnly: 관측 \(rFace.quality.observedRatio) 채움 \(rFace.quality.filledRatio)")
        #expect(rFace.quality.observedRatio < rFull.quality.observedRatio, "faceOnly 는 얼굴 밖을 안 보니 관측 비율이 더 낮아야 한다")
        #expect(rFace.quality.filledRatio > rFull.quality.filledRatio, "그 자리는 채움이 대신 메워야 한다")
    }

    @Test("faceOnly 로 만든 얼굴 패치 영역 자체의 품질은 전체 모드와 비슷하다(얼굴까지 건너뛰지 않는다)")
    func faceOnlyStillCoversFacePatch() throws {
        let t = Self.template
        let b = Self.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var full = TextureBuildOptions(); full.size = 256; full.supersample = 1
        let rFull = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: full)
        let rFace = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: .faceOnlyPreset(size: 256, splatColorSize: 64))
        // 얼굴 영역(uvRegions.face, v < 0.5)만 떼서 비교 — 거기는 두 모드가 거의 같아야 한다.
        func faceObservedRatio(_ img: RGBAImage) -> Float {
            var observed = 0, total = 0
            for y in 0..<(img.height / 2) { for x in 0..<img.width {
                total += 1
                if img[x, y].w > 0 { observed += 1 }
            } }
            return total > 0 ? Float(observed) / Float(total) : 0
        }
        let full2 = faceObservedRatio(rFull.mask), face2 = faceObservedRatio(rFace.mask)
        print("얼굴 영역 관측 비율: 전체 \(full2) · faceOnly \(face2)")
        #expect(abs(full2 - face2) < 0.05, "얼굴 영역 관측 비율이 달라짐 — faceOnly 가 얼굴까지 건너뛰고 있을 수 있다")
    }
}
