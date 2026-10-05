import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaTexture
@testable import CoursonaIO

@Suite("scratch3")
struct TextureScratch {
    @Test("error map")
    func errorMap() throws {
        let t = TextureBuilderTests.template
        let b = TextureBuilderTests.bundle()
        let id = Identity.fromTemplate(t)
        let a = FaceFitter.alignments(bundle: b, template: t)
        var o = TextureBuildOptions(); o.size = 256; o.supersample = 3; o.preferMetal = true; o.delight = 1; o.skinFilter = false
        let r = try TextureBuilder.build(bundle: b, template: t, identity: id, alignments: a, options: o)
        let truth = TextureBuilderTests.truth(size: 256, samples: 3)
        var err = RGBAImage(width: 256, height: 256)
        var regions: [(String, (Float, Float) -> Bool)] = [("face v<0.5", { _, v in v < 0.5 }), ("head 0.5–0.85", { _, v in v >= 0.5 && v < 0.85 }), ("torso v>0.85", { _, v in v >= 0.85 })]
        regions.append(("face 중앙 u 0.3–0.7 v 0.1–0.45", { u, v in u > 0.3 && u < 0.7 && v > 0.1 && v < 0.45 }))
        for (name, pred) in regions {
            var mse = 0.0; var n = 0
            for y in 0..<256 { for x in 0..<256 where r.mask[x, y].x > 127 {
                let u = (Float(x) + 0.5) / 256, v = 1 - (Float(y) + 0.5) / 256
                guard pred(u, v) else { continue }
                let c = r.albedo[x, y], d = truth[x, y]
                for k in 0..<3 { let e = Double(Int(c[k]) - Int(d[k])); mse += e * e }
                n += 3
            } }
            print(String(format: "%@: PSNR %.1f dB (n %d)", name, n > 0 ? 10 * log10(255 * 255 / (mse / Double(n))) : -1, n / 3))
        }
        var hist = [Int](repeating: 0, count: 8)
        for y in 0..<256 { for x in 0..<256 {
            let c = r.albedo[x, y], d = truth[x, y]
            let e = r.mask[x, y].x > 127 ? max(abs(Int(c.x) - Int(d.x)), abs(Int(c.y) - Int(d.y)), abs(Int(c.z) - Int(d.z))) : 0
            err[x, y] = SIMD4(UInt8(min(255, e * 4)), UInt8(min(255, e * 4)), UInt8(min(255, e * 4)), 255)
            if r.mask[x, y].x > 127 { hist[min(7, e / 8)] += 1 }
        } }
        print("오차 히스토그램(8/255 단위): \(hist)")
        try? FileManager.default.createDirectory(atPath: "/tmp/coursona-fit", withIntermediateDirectories: true)
        try ImageCodec.png(r.albedo).write(to: URL(fileURLWithPath: "/tmp/coursona-fit/tex-albedo.png"))
        try ImageCodec.png(truth).write(to: URL(fileURLWithPath: "/tmp/coursona-fit/tex-truth.png"))
        try ImageCodec.png(err).write(to: URL(fileURLWithPath: "/tmp/coursona-fit/tex-err.png"))
        try ImageCodec.png(r.mask).write(to: URL(fileURLWithPath: "/tmp/coursona-fit/tex-mask.png"))
        if let img = b.shot(.front)?.image { try ImageCodec.png(img).write(to: URL(fileURLWithPath: "/tmp/coursona-fit/tex-front.png")) }
    }
}
