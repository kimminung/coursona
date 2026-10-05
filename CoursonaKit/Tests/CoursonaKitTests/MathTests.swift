import Testing
import simd
@testable import CoursonaCore

@Suite("수학")
struct MathTests {
    @Test("Procrustes 가 임의의 유사 변환을 복원한다")
    func procrustesRecovers() {
        var rng = SystemRandomNumberGenerator()
        let pts: [SIMD3<Float>] = (0..<50).map { _ in SIMD3(Float.random(in: -0.1...0.1, using: &rng), Float.random(in: -0.1...0.1, using: &rng), Float.random(in: -0.1...0.1, using: &rng)) }
        let q = simd_normalize(simd_quatf(ix: 0.2, iy: -0.5, iz: 0.1, r: 0.8))
        let s: Float = 1.07
        let tr = SIMD3<Float>(0.3, -0.2, 0.5)
        let target = pts.map { q.act($0) * s + tr }
        let T = Procrustes.fit(source: pts, target: target)!
        #expect(abs(T.scale - s) < 1e-4)
        #expect(Procrustes.rms(source: pts, target: target, transform: T) < 1e-5)
        let T2 = Procrustes.fit(source: pts, target: target, allowScale: false)!
        #expect(T2.scale == 1)
    }

    @Test("바이하모닉 RBF 가 아핀 변위를 중심 밖에서도 재현한다")
    func rbfReproducesAffine() {
        let centers: [SIMD3<Float>] = (0..<60).map { i in
            let a = Float(i) * 0.7
            return SIMD3(0.05 * cos(a), 0.4 + 0.004 * Float(i), 0.05 * sin(a) + 0.03)
        }
        let f: (SIMD3<Float>) -> SIMD3<Float> = { p in SIMD3(0.1 * p.x + 0.002, -0.05 * p.y + 0.001, 0.02 * p.z) }
        let rbf = BiharmonicRBF(centers: centers, values: centers.map(f))!
        for p in [SIMD3<Float>(0.07, 0.45, 0.0), SIMD3(-0.03, 0.55, -0.02), SIMD3(0.0, 0.3, 0.09)] {
            let e = simd_length(rbf.evaluate(p) - f(p))
            #expect(e < 1e-4, "오차 \(e) at \(p)")
        }
        // 중심에서는 정확히 보간
        #expect(simd_length(rbf.evaluate(centers[7]) - f(centers[7])) < 1e-5)
    }

    @Test("TPS 가 대응점을 지난다")
    func tpsInterpolates() {
        let src: [SIMD2<Float>] = [[0, 0], [1, 0], [0, 1], [1, 1], [0.5, 0.5], [0.2, 0.8]]
        let dst: [SIMD2<Float>] = [[0, 0], [1.1, 0.05], [0, 1], [1, 1.05], [0.55, 0.5], [0.2, 0.85]]
        let tps = ThinPlateSpline(source: src, target: dst, lambda: 0)!
        for (s, d) in zip(src, dst) { #expect(simd_length(tps.map(s) - d) < 1e-3) }
    }

    @Test("Intrinsics 투영/역투영 왕복")
    func intrinsicsRoundTrip() {
        let K = Geometry.intrinsics(verticalFOV: 0.8, width: 640, height: 480)
        let p = SIMD3<Float>(0.03, -0.02, -0.45)
        let px = K.project(p)!
        let back = K.unproject(px, depth: 0.45)
        #expect(simd_length(back - p) < 1e-5)
    }

    @Test("한글 비셈: 초성 ㅁ 은 폐쇄 후 모음, 받침 ㅂ 은 폐쇄")
    func hangulViseme() {
        let steps = HangulViseme.visemes(for: "맙", secondsPerSyllable: 0.2)
        #expect(steps.map(\.viseme) == [.press, .A, .press])
        #expect(abs(HangulViseme.duration(of: steps) - (0.2 + 0.08)) < 1e-4)
    }

    @Test("ArkitWeights 이름 왕복·미러")
    func arkitWeights() {
        var w = ArkitWeights()
        w[.jawOpen] = 0.5; w[.mouthSmileLeft] = 0.3
        let back = ArkitWeights(named: w.named)
        #expect(back == w)
        #expect(ArkitShape.mouthSmileLeft.mirrored == .mouthSmileRight)
        #expect(ArkitShape.jawLeft.mirrored == .jawRight)
        #expect(ArkitShape.count == 52)
    }
}
