import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaSplat

/// C5 T-503: `splats.bin` 왕복.
@Suite("splats.bin 왕복 (C5, T-503)")
struct SplatFileTests {
    static func sample() -> [SplatRecord] {
        [
            SplatRecord(position: SIMD3(0.01, 0.4, 0.08), scale: SIMD3(0.002, 0.002, 0.0007),
                       rotation: simd_quatf(angle: 0.5, axis: [0, 0, 1]),
                       color: SIMD3(0.6, 0.4, 0.3), opacity: 0.95, triangle: 42, baryU: 0.3, baryV: 0.4, normalOffset: 0.0015),
            SplatRecord(position: SIMD3(-0.02, 0.5, -0.03), scale: SIMD3(0.003, 0.003, 0.001),
                       rotation: simd_quatf(angle: 1.2, axis: simd_normalize(SIMD3(1, 1, 0))),
                       color: SIMD3(0.1, 0.9, 0.2), opacity: 0.6, triangle: 1000, baryU: 0.6, baryV: 0.2, normalOffset: 0.0045),
        ]
    }

    @Test("바인딩 포함 왕복 — 위치·스케일·회전·색·불투명도·삼각형/바리센트릭/오프셋까지 전부 보존")
    func roundTripWithBinding() throws {
        let records = Self.sample()
        let data = SplatFile.write(records, includeBinding: true)
        #expect(data.count == 4 + 16 + records.count * (SplatFile.dataStride + 16))
        let back = try SplatFile.read(data)
        #expect(back.count == records.count)
        for (a, b) in zip(records, back) {
            #expect(simd_length(a.position - b.position) < 1e-6)
            #expect(simd_length(a.scale - b.scale) < 1e-6)
            #expect(simd_length(a.rotation.vector - b.rotation.vector) < 1e-6)
            #expect(simd_length(a.color - b.color) < 1e-6)
            #expect(abs(a.opacity - b.opacity) < 1e-6)
            #expect(a.triangle == b.triangle)
            #expect(abs(a.baryU - b.baryU) < 1e-6 && abs(a.baryV - b.baryV) < 1e-6)
            #expect(abs(a.normalOffset - b.normalOffset) < 1e-6)
        }
    }

    @Test("바인딩 없이 쓰면 더 작고, 읽으면 triangle 이 -1(미기록) 로 온다")
    func roundTripWithoutBinding() throws {
        let records = Self.sample()
        let withB = SplatFile.write(records, includeBinding: true)
        let withoutB = SplatFile.write(records, includeBinding: false)
        #expect(withoutB.count < withB.count)
        let back = try SplatFile.read(withoutB)
        #expect(back.count == records.count)
        for r in back { #expect(r.triangle == -1) }
        // 렌더용 값은 그대로.
        #expect(simd_length(back[0].position - records[0].position) < 1e-6)
    }

    @Test("매직이 틀리면 badMagic 오류")
    func badMagicThrows() {
        var data = SplatFile.write(Self.sample())
        data[0] = 0
        #expect(throws: SplatFileError.self) { try SplatFile.read(data) }
    }

    @Test("길이가 모자라면 truncated 오류")
    func truncatedThrows() {
        let data = SplatFile.write(Self.sample()).dropLast(10)
        #expect(throws: SplatFileError.self) { try SplatFile.read(Data(data)) }
    }
}
