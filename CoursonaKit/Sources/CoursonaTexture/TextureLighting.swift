//
//  TextureLighting.swift
//  CoursonaTexture
//
//  T-404 탈조명의 조명 추정. T-007 실기기 결과대로 ARKit 은 방향 추정을 늘 주지 않으므로(그리고 줄 때도 얼굴 기준이 아니므로)
//  **얼굴 자체에서** 추정한다: 컷의 ARKit 패치 정점(템플릿 공간)을 사진에 투영해 밝기 b_i 를 읽고, 카메라를 향한 **피부색** 정점만으로
//  b ≈ a + d·n (4 미지수, 최소제곱) 을 푼다 → 빛 방향 ℓ = d̂(표면에서 광원 쪽), 주변광 비율 f = a/(a+|d|).
//  강건화: 색도가 피부 중앙값에서 먼 표본(입술·눈썹) 제외 → 3회 반복하며 그늘(n·ℓ < 0.05, 램버트 클램프 영역)·이상치(2σ) 제외.
//  음영 모델 shade = f + (1−f)·max(0, n·ℓ) — 가장 밝은 면이 1 이라 탈조명은 **그늘만 밝히고 밝은 면은 그대로** 둔다.
//  고정 0.35/0.65 를 쓰던 M0 투영기는 실제 조명(평평한 실내광)에서 과보정한다. 대비 (1−f)/f 가 0.08 미만이면 그 컷은 탈조명하지 않는다.
//

import Foundation
import simd
import CoursonaCore

public struct LightEstimateResult: Sendable, Equatable {
    /// 표면에서 광원을 향하는 단위 벡터 (템플릿 공간)
    public var towardLight: SIMD3<Float>
    /// 주변광 비율 f (0…1). 0.35 = 합성 캡처 모델
    public var ambientFraction: Float
    /// 직접광/주변광 대비 (1−f)/f
    public var contrast: Float { (1 - ambientFraction) / max(1e-3, ambientFraction) }
    public var samples: Int
    public var source: String   // "face" | "arkit"
    public init(towardLight: SIMD3<Float>, ambientFraction: Float, samples: Int, source: String) {
        self.towardLight = towardLight; self.ambientFraction = ambientFraction; self.samples = samples; self.source = source
    }
}

public enum TextureLighting {
    public static let minContrast: Float = 0.08

    /// 램버트 음영: f + (1−f)·max(0, n·ℓ). 가장 밝은 면 = 1.
    @inline(__always) public static func shade(normal n: SIMD3<Float>, light l: LightEstimateResult) -> Float {
        l.ambientFraction + (1 - l.ambientFraction) * max(0, simd_dot(n, l.towardLight))
    }

    /// 탈조명 배율: 강도 0 → 1 (원본 그대로).
    @inline(__always) public static func delightFactor(shade: Float, strength: Float) -> Float {
        let inv = 1 / max(0.25, shade)
        return 1 + (inv - 1) * strength
    }

    /// 컷 하나의 조명 추정. `F` = 얼굴 → 템플릿, 카메라는 템플릿 공간(`cameraToTemplate`).
    public static func estimate(shot: CaptureShot, template t: BustTemplate, faceToTemplate F: simd_float4x4,
                                cameraToTemplate M: simd_float4x4) -> LightEstimateResult? {
        guard let img = shot.image else { return nil }
        let raw = shot.meta.faceVertexArray
        let pc = t.patchCount
        guard raw.count == pc else { return nil }
        var tris: [UInt32] = []
        var k = 0
        while k + 2 < t.indices.count {
            let a = t.indices[k], b = t.indices[k + 1], c = t.indices[k + 2]
            if a < pc, b < pc, c < pc { tris += [a, b, c] }
            k += 3
        }
        let pos = raw.map { Geometry.transformPoint(F, $0) }
        let normals = Geometry.vertexNormals(positions: pos, indices: tris)
        let K = shot.meta.intrinsics.scaled(toWidth: img.width, height: img.height)
        let Minv = M.inverse
        let camPos = SIMD3(M.columns.3.x, M.columns.3.y, M.columns.3.z)
        // 표본: (법선, 밝기, 색도)
        var ns: [SIMD3<Float>] = [], lums: [Float] = [], chroma: [SIMD2<Float>] = []
        for i in 0..<pc {
            let p = pos[i], nn = normals[i]
            guard simd_dot(nn, simd_normalize(camPos - p)) > 0.3 else { continue }
            guard let px = K.project(Geometry.transformPoint(Minv, p)), let c = img.sample(px) else { continue }
            let sum = max(1e-3, c.x + c.y + c.z)
            ns.append(nn); lums.append(0.3 * c.x + 0.59 * c.y + 0.11 * c.z); chroma.append(SIMD2(c.x / sum, c.y / sum))
        }
        guard ns.count >= 60 else { return nil }
        // 피부 색도: 중앙값 근처만
        let medR = chroma.map(\.x).sorted()[chroma.count / 2], medG = chroma.map(\.y).sorted()[chroma.count / 2]
        var active = (0..<ns.count).filter { simd_length(chroma[$0] - SIMD2(medR, medG)) < 0.04 }
        if active.count < 40 { active = Array(0..<ns.count) }
        var result: (a: Float, d: SIMD3<Float>)? = nil
        for _ in 0..<3 {
            var A = [Double](repeating: 0, count: 16), bvec = [Double](repeating: 0, count: 4)
            for i in active {
                let row = [1.0, Double(ns[i].x), Double(ns[i].y), Double(ns[i].z)]
                for r in 0..<4 { for q in 0..<4 { A[r * 4 + q] += row[r] * row[q] }; bvec[r] += row[r] * Double(lums[i]) }
            }
            guard let x = DenseSolver.solve(A, bvec, n: 4) else { break }
            let a = Float(x[0]), d = SIMD3<Float>(Float(x[1]), Float(x[2]), Float(x[3]))
            result = (a, d)
            let len = simd_length(d)
            guard len > 1e-5 else { break }
            let l = d / len
            // 잔차 σ, 그늘·이상치 제외
            var res: [Float] = []
            for i in active { res.append(lums[i] - (a + simd_dot(d, ns[i]))) }
            let sigma = max(1e-3, (res.reduce(0) { $0 + $1 * $1 } / Float(max(1, res.count))).squareRoot())
            let next = active.enumerated().filter { simd_dot(ns[$0.element], l) > 0.05 && abs(res[$0.offset]) < 2 * sigma }.map(\.element)
            guard next.count >= 40, next.count != active.count else { break }
            active = next
        }
        guard let (a, d) = result else { return nil }
        let len = simd_length(d)
        guard a > 1e-3, len > 1e-5 else { return nil }
        let f = min(0.95, max(0.1, a / (a + len)))
        return LightEstimateResult(towardLight: d / len, ambientFraction: f, samples: active.count, source: "face")
    }

    /// ARKit 추정(월드, 빛 진행 방향)을 템플릿 공간의 "광원 쪽" 벡터로. 주변광 비율은 모르므로 0.35.
    public static func fromARKit(shot: CaptureShot, faceToTemplate F: simd_float4x4) -> LightEstimateResult? {
        guard let pd = shot.meta.light.primaryDirection, pd.count == 3 else { return nil }
        let dirWorld = SIMD3<Float>(pd[0], pd[1], pd[2])
        let dt = Geometry.transformDirection(F * shot.faceTransform.inverse, dirWorld)
        guard simd_length_squared(dt) > 1e-8 else { return nil }
        return LightEstimateResult(towardLight: -simd_normalize(dt), ambientFraction: 0.35, samples: 0, source: "arkit")
    }

    /// 뺨 영역 패치 정점 (정면 컷 재정규화 기준, TechPRD §10): 입꼬리와 눈 바깥 꼬리 사이 높이, 코 옆, 앞면.
    public static func cheekVertices(template t: BustTemplate) -> [Int] {
        let m = t.manifest
        guard let eo = m.landmark(.eyeLeftOuter), let ml = m.landmark(.mouthLeft), let nose = m.landmark(.noseTip) else { return [] }
        let p = t.positions
        let yTop = p[eo].y - 0.005, yBottom = p[ml].y
        let xOut = abs(p[eo].x) * 1.15, xIn = abs(p[eo].x) * 0.45
        var out: [Int] = []
        for i in 0..<t.patchCount {
            let q = p[i]
            if q.y < yTop, q.y > yBottom, abs(q.x) > xIn, abs(q.x) < xOut, q.z > p[nose].z - 0.05 { out.append(i) }
        }
        return out
    }
}
