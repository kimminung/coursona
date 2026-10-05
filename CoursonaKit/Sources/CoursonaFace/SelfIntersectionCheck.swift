//
//  SelfIntersectionCheck.swift
//  CoursonaFace
//
//  자기교차 검사 (TechPRD §6.4 F9, Tasks T-207·T-209). 분리된 눈알·치아가 없으니 "돌출"이 아니라
//  "겹침" 만 있을 수 있다 — 캡(중간 고리+중심)이 표정을 따라가다 뒤집히는지를 본다.
//
//  진짜 삼각형-삼각형 교차 테스트 대신 **법선 뒤집힘**으로 근사한다: 중립 자세에서의 캡 삼각형 법선과
//  어떤 셰이프를 1.0 으로 줬을 때의 같은 삼각형 법선이 서로 반대를 향하면(내적 < 0) 그 삼각형은 뒤집힌 것이고,
//  뒤집힌 캡 삼각형은 거의 항상 자기 자신(또는 반대쪽 벽)과 겹친다. 적은 계산으로 "의심 신호"를 잡는 1차 검사다.
//

import Foundation
import simd
import CoursonaCore

public enum SelfIntersectionCheck {
    public struct ShapeReport: Sendable, Equatable {
        public var shape: ArkitShape
        public var flippedTriangles: Int
    }

    /// 중립(캡 건설 자체)과 셰이프 델타가 있는 셰이프 각각 1.0 에서 캡 삼각형이 뒤집히는지 검사한다.
    /// `result.template` 은 `CapBuilder.addingCaps` 의 결과(= 캡이 이미 더해진 템플릿)여야 한다.
    public static func check(_ result: CapBuildResult) -> [ShapeReport] {
        let t = result.template
        let caps = result.caps
        guard !caps.isEmpty else { return [] }
        var reports: [ShapeReport] = []
        for (shape, deltas) in t.shapeDeltas where deltas.count == t.positions.count {
            var flipped = 0
            for cap in caps {
                var k = cap.triangleIndexRange.lowerBound
                while k < cap.triangleIndexRange.upperBound {
                    let a = Int(t.indices[k]), b = Int(t.indices[k + 1]), c = Int(t.indices[k + 2])
                    let nRest = simd_cross(t.positions[b] - t.positions[a], t.positions[c] - t.positions[a])
                    let pa = t.positions[a] + deltas[a], pb = t.positions[b] + deltas[b], pc = t.positions[c] + deltas[c]
                    let nPose = simd_cross(pb - pa, pc - pa)
                    if simd_dot(nRest, nPose) < 0 { flipped += 1 }
                    k += 3
                }
            }
            if flipped > 0 { reports.append(ShapeReport(shape: shape, flippedTriangles: flipped)) }
        }
        return reports
    }
}
