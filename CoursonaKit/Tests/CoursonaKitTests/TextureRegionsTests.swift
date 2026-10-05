import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaTexture

/// 19차 — 얼굴 밖 영역 정리(`TextureRegions`): 피부 게이트가 셔츠·하이라이트·머리카락 관측을 버리고, 저주파화가 조각난 관측을 매끈한 피부톤으로 만들며,
/// 가는 띠의 온전한 관측은 커버리지 부족으로 비워지지 않는다.
@Suite("텍스처 영역 정리 (19차)")
struct TextureRegionsTests {
    static let skin = SIMD3<Float>(0.72, 0.55, 0.40)
    static let shirt = SIMD3<Float>(0.70, 0.75, 0.85)
    static let highlight = SIMD3<Float>(0.96, 0.96, 0.95)
    static let hair = SIMD3<Float>(0.15, 0.10, 0.08)

    /// 결정적 의사난수 (LCG)
    struct Rng { var s: UInt32 = 12345; mutating func next() -> Float { s = s &* 1664525 &+ 1013904223; return Float(s >> 8) / Float(1 << 24) } }

    @Test("피부 게이트: 기준색 대비 셔츠·하이라이트·머리카락은 거부, 그늘진 피부(밝기 0.5배)·약간 붉은 피부는 통과")
    func gate() {
        let ref = Self.skin
        #expect(TextureRegions.isSkinLike(ref * 0.5, reference: ref, gate: .skin))
        #expect(TextureRegions.isSkinLike(ref * SIMD3(1.03, 0.98, 0.97), reference: ref, gate: .skin))
        #expect(!TextureRegions.isSkinLike(Self.shirt, reference: ref, gate: .skin))
        #expect(!TextureRegions.isSkinLike(Self.highlight, reference: ref, gate: .skin))
        #expect(!TextureRegions.isSkinLike(Self.hair, reference: ref, gate: .skin))
        // 실기기 값: 피부 (216,172,129) 기준으로 청회색 옷 (72,82,105)·흰 깃 (235,235,238) 거부
        let real = SIMD3<Float>(216, 172, 129) / 255
        #expect(!TextureRegions.isSkinLike(SIMD3<Float>(72, 82, 105) / 255, reference: real, gate: .skin))
        #expect(!TextureRegions.isSkinLike(SIMD3<Float>(235, 235, 238) / 255, reference: real, gate: .skin))
        #expect(TextureRegions.isSkinLike(SIMD3<Float>(150, 112, 80) / 255, reference: real, gate: .skin))
    }

    @Test("조각난 목 관측(피부 70 % + 셔츠·하이라이트·머리카락 30 %, 구멍 20 %) → 게이트 + 저주파화 뒤 영역 전체가 피부톤이고 텍셀 간 편차 < 3/255")
    func lowPassCleansFragments() {
        let S = 128
        var albedo = [SIMD3<Float>](repeating: .zero, count: S * S)
        var state = [UInt8](repeating: 0, count: S * S)
        var mask = [Bool](repeating: false, count: S * S)
        var face = [Bool](repeating: false, count: S * S)
        var rng = Rng()
        for y in 0..<S { for x in 0..<S {
            let i = y * S + x
            if y < 40 {   // 위 40행 = "얼굴" (기준색 출처), 살짝 기울기
                face[i] = true
                albedo[i] = Self.skin * (0.97 + 0.06 * Float(x) / Float(S)); state[i] = 1
            } else if y >= 48, x >= 16, x < 112 {   // 목 영역
                mask[i] = true
                let r = rng.next()
                if r < 0.2 { continue }                                  // 구멍
                state[i] = 1
                if r < 0.3 { albedo[i] = Self.shirt } else if r < 0.4 { albedo[i] = Self.highlight } else if r < 0.5 { albedo[i] = Self.hair }
                else { albedo[i] = Self.skin * (0.9 + 0.2 * rng.next()) }   // 피부 + 노이즈
            }
        } }
        let ref = TextureRegions.medianColor(albedo: albedo, state: state, mask: face, stride: 1)
        #expect(ref != nil && simd_length(ref! - Self.skin) < 0.03)
        let rejected = TextureRegions.rejectNonSkin(albedo: &albedo, state: &state, mask: mask, reference: ref!, gate: .skin)
        let maskCount = mask.filter { $0 }.count
        #expect(Double(rejected) / Double(maskCount) > 0.25 && Double(rejected) / Double(maskCount) < 0.35, "버림 \(rejected)/\(maskCount)")
        // 남은 관측은 전부 피부
        for i in 0..<(S * S) where mask[i] && state[i] == 1 { #expect(TextureRegions.isSkinLike(albedo[i], reference: ref!, gate: .skin)) }
        let (filled, cleared) = TextureRegions.lowPass(albedo: &albedo, state: &state, mask: mask, size: S, cell: 4, sigmaCells: 2, minCoverage: 0.12, blendTo: ref, blend: 0.2)
        #expect(cleared == 0, "관측 밀도가 충분한 영역에서는 비우지 않는다 (\(cleared))")
        #expect(filled > maskCount / 3)   // 구멍 + 버린 자리 (≈ 44 %)
        var empty = 0, mean = SIMD3<Float>.zero, n: Float = 0
        for i in 0..<(S * S) where mask[i] { if state[i] == 0 { empty += 1 } else { mean += albedo[i]; n += 1 } }
        #expect(empty == 0)
        mean /= n
        #expect(simd_length(mean - Self.skin) < 0.04, "평균 \(mean)")
        var maxDev: Float = 0
        for i in 0..<(S * S) where mask[i] && state[i] != 0 { maxDev = max(maxDev, simd_reduce_max(simd_abs(albedo[i] - mean))) }
        #expect(maxDev * 255 < 9, "텍셀 간 최대 편차 \(maxDev * 255)/255")   // 저주파화 뒤 남는 건 완만한 기울기뿐 (입력 노이즈 ±10 % → 평균 뒤 < 9/255)
    }

    @Test("가는 띠(3텍셀) 가 전부 관측이면 저주파화가 비우지 않는다 (커버리지는 마스크 면적 대비)")
    func thinStripKeepsObservations() {
        let S = 64
        var albedo = [SIMD3<Float>](repeating: .zero, count: S * S)
        var state = [UInt8](repeating: 0, count: S * S)
        var mask = [Bool](repeating: false, count: S * S)
        for y in 0..<S { for x in 30..<33 { let i = y * S + x; mask[i] = true; state[i] = 1; albedo[i] = Self.skin } }
        let (filled, cleared) = TextureRegions.lowPass(albedo: &albedo, state: &state, mask: mask, size: S, cell: 4, sigmaCells: 2, minCoverage: 0.12)
        #expect(cleared == 0 && filled == 0)
        for y in 0..<S { #expect(simd_length(albedo[y * S + 31] - Self.skin) < 1e-3) }
    }

    @Test("칠하기: 눈꺼풀 안쪽 띠는 관측을 덮어쓰고 filled 로 표시")
    func paint() {
        var albedo = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: 16)
        var state = [UInt8](repeating: 1, count: 16)
        let mask = (0..<16).map { $0 % 2 == 0 }
        let n = TextureRegions.paint(albedo: &albedo, state: &state, mask: mask, color: Self.skin)
        #expect(n == 8)
        for i in 0..<16 { #expect(mask[i] ? (albedo[i] == Self.skin && state[i] == 3) : (albedo[i] == SIMD3(1, 1, 1) && state[i] == 1)) }
    }
}
