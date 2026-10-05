//
//  SphereFit.swift
//  CoursonaCore
//
//  눈알 추정(T-302)용 작은 기하: 대수적 구 피팅, 순서 있는 루프의 법선(Newell), 루프 평면 반지름.
//  순수 Swift·결정적. 눈꺼풀 링(24점)은 거의 한 평면의 원이라 구가 한 매개변수만큼 자유롭다 — 호출 쪽(FacePatchSolver)이
//  반지름 사전값으로 결과를 검증하고 받아들일지 정한다.
//

import Foundation
import simd

public enum SphereFit {
    public struct Sphere: Sendable, Equatable {
        public var center: SIMD3<Float>
        public var radius: Float
    }

    /// 대수적 최소제곱 구 피팅: |p|² + a·p + d = 0 (선형 4 미지수). 점 4개 미만·퇴화면 nil.
    public static func algebraic(_ points: [SIMD3<Float>]) -> Sphere? {
        guard points.count >= 4 else { return nil }
        // 수치 안정: 무게중심 기준 좌표
        let m = points.reduce(.zero, +) / Float(points.count)
        var A = [Double](repeating: 0, count: 16)
        var b = [Double](repeating: 0, count: 4)
        for p in points {
            let q = SIMD3<Double>(p - m)
            let row = [q.x, q.y, q.z, 1.0]
            let rhs = -(q.x * q.x + q.y * q.y + q.z * q.z)
            for i in 0..<4 {
                for j in 0..<4 { A[i * 4 + j] += row[i] * row[j] }
                b[i] += row[i] * rhs
            }
        }
        guard let x = DenseSolver.solve(A, b, n: 4) else { return nil }
        let c = SIMD3<Double>(-x[0] / 2, -x[1] / 2, -x[2] / 2)
        let r2 = simd_length_squared(c) - x[3]
        guard r2 > 0, r2.isFinite else { return nil }
        return Sphere(center: SIMD3<Float>(c) + m, radius: Float(r2.squareRoot()))
    }

    /// 순서 있는 닫힌 루프의 법선 (Newell). 반시계(루프 순서) 기준 오른손 법선. 길이 0 이면 nil.
    public static func loopNormal(_ loop: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard loop.count >= 3 else { return nil }
        var n = SIMD3<Float>.zero
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        let l = simd_length(n)
        return l > 1e-12 ? n / l : nil
    }

    /// 루프 점들의 평면 내 평균 반지름 (무게중심 기준, 법선 성분 제외).
    public static func loopRadius(_ loop: [SIMD3<Float>], normal n: SIMD3<Float>) -> Float {
        guard !loop.isEmpty else { return 0 }
        let m = loop.reduce(.zero, +) / Float(loop.count)
        var s: Float = 0
        for p in loop {
            let d = p - m
            let perp = d - n * simd_dot(d, n)
            s += simd_length(perp)
        }
        return s / Float(loop.count)
    }
}
