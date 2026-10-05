//
//  BiharmonicRBF.swift
//  CoursonaCore
//
//  3D 바이하모닉 RBF(커널 φ(r) = r³) + 1차 다항식. 얼굴 패치 변위 d_i 를 패치 밖(두상·귀·목)으로 전파한다(TechPRD §6.4-3).
//  시스템 [[K + λI, P], [Pᵀ, 0]] (n+4). 중심은 ≈ 300 개(경계 200 + 내부 100)로 제한해 O(n³) 풀이가 수 ms 안에 끝난다.
//

import Foundation
import simd

public struct BiharmonicRBF: Sendable {
    /// 정규화 좌표계의 중심 ((원래 − origin) × invScale)
    public let centers: [SIMD3<Float>]
    /// 중심별 가중치 (x,y,z 출력 각각)
    public let weights: [SIMD3<Double>]
    /// 아핀 [a0, ax, ay, az] (정규화 좌표 기준)
    public let affine: [SIMD3<Double>]
    /// 풀이 조건 근사 (피벗 비). 1e12 초과면 λ 를 올려 다시 푼 값이 들어 있다.
    public let pivotRatio: Double
    /// 실제로 쓴 정규화 (정규화 좌표 단위 — 커널 r³ 가 O(1) 인 척도).
    public let lambda: Double
    /// 입력 좌표 정규화: 중심의 무게중심·평균 거리. r³ + 1차 다항식 보간은 평행이동·균일 스케일에 불변이라 결과는 같고
    /// 조건수만 좋아진다 (m 단위 그대로 두면 r³ ≈ 1e-5 와 다항식 블록 1 이 섞여 중심이 적을 때(희소 피팅 8점) 피벗비가 1e12 를 넘어
    /// 불필요한 λ 가 들어갔다 — M3 에서 발견).
    public let origin: SIMD3<Float>
    public let invScale: Float

    /// - Parameters:
    ///   - centers: 중심점(패치 경계·내부 샘플)
    ///   - values: 중심에서의 변위
    ///   - lambda: 정규화. 수치 불안정(피벗 비 > 1e12)이면 자동으로 1e-6 부터 10배씩 키우며 재시도하고 `lambda` 에 기록한다.
    public init?(centers rawCenters: [SIMD3<Float>], values: [SIMD3<Float>], lambda: Double = 0) {
        let n = rawCenters.count
        guard n >= 4, values.count == n else { return nil }
        // 중복 중심 제거(같은 점이 두 번 들어오면 특이 행렬)
        var uniq: [SIMD3<Float>] = [], uval: [SIMD3<Float>] = []
        uniq.reserveCapacity(n); uval.reserveCapacity(n)
        outer: for i in 0..<n {
            for u in uniq where simd_length_squared(u - rawCenters[i]) < 1e-14 { continue outer }
            uniq.append(rawCenters[i]); uval.append(values[i])
        }
        guard uniq.count >= 4 else { return nil }
        // 좌표 정규화
        let o = uniq.reduce(.zero, +) / Float(uniq.count)
        var meanR: Float = 0
        for p in uniq { meanR += simd_length(p - o) }
        meanR = max(1e-6, meanR / Float(uniq.count))
        origin = o
        invScale = 1 / meanR
        let c = uniq.map { ($0 - o) / meanR }, v = uval, m = c.count + 4

        var lam = lambda
        var attempt = 0
        var solution: DenseSolver.Solution?
        while attempt < 6 {
            var L = [Double](repeating: 0, count: m * m)
            for i in 0..<c.count {
                for j in i..<c.count {
                    let r = Double(simd_length(c[i] - c[j]))
                    let k = r * r * r + (i == j ? lam : 0)
                    L[i * m + j] = k; L[j * m + i] = k
                }
                let p = c[i]
                L[i * m + c.count] = 1; L[i * m + c.count + 1] = Double(p.x); L[i * m + c.count + 2] = Double(p.y); L[i * m + c.count + 3] = Double(p.z)
                L[c.count * m + i] = 1; L[(c.count + 1) * m + i] = Double(p.x); L[(c.count + 2) * m + i] = Double(p.y); L[(c.count + 3) * m + i] = Double(p.z)
            }
            var B = [Double](repeating: 0, count: m * 3)
            for i in 0..<c.count { B[i * 3] = Double(v[i].x); B[i * 3 + 1] = Double(v[i].y); B[i * 3 + 2] = Double(v[i].z) }
            if let s = DenseSolver.solve(L, B, n: m, k: 3), s.pivotRatio < 1e12, s.x.allSatisfy({ $0.isFinite }) {
                solution = s
                break
            }
            lam = lam == 0 ? 1e-6 : lam * 10
            attempt += 1
        }
        guard let sol = solution else { return nil }
        self.centers = c
        weights = (0..<c.count).map { SIMD3(sol.x[$0 * 3], sol.x[$0 * 3 + 1], sol.x[$0 * 3 + 2]) }
        affine = (0..<4).map { SIMD3(sol.x[(c.count + $0) * 3], sol.x[(c.count + $0) * 3 + 1], sol.x[(c.count + $0) * 3 + 2]) }
        pivotRatio = sol.pivotRatio
        self.lambda = lam
    }

    public func evaluate(_ raw: SIMD3<Float>) -> SIMD3<Float> {
        let p = (raw - origin) * invScale
        var out = affine[0] + affine[1] * Double(p.x) + affine[2] * Double(p.y) + affine[3] * Double(p.z)
        for i in centers.indices {
            let r = Double(simd_length(p - centers[i]))
            if r > 0 { out += weights[i] * (r * r * r) }
        }
        return SIMD3<Float>(Float(out.x), Float(out.y), Float(out.z))
    }
}
