//
//  DeltaCalibrator.swift
//  CoursonaFit
//
//  T-305 셰이프 델타 보정. 패치 델타는 ARKit 대응(동일 토폴로지)이라 그대로, 패치 밖은 `Identity.scale`(런타임, `runtimeDeltas`).
//  여기서는 **jawOpen 진폭**만 사용자 데이터로 맞춘다: 미소 컷(정렬·템플릿 공간)에서 관측된 변위 = 사용자 중립 패치 대비 차이.
//  관측 − (jawOpen 을 뺀 나머지 셰이프의 예측) 을 w_jaw·Δ_jaw 에 최소제곱 투영한 비율 r 이 사용자의 턱 벌림 진폭이다
//  (턱 영역 = |Δ_jaw| 가 최대의 30 % 이상인 패치 정점). 미소 컷에 jawOpen 이 거의 없으면(< 0.08) 보정하지 않는다.
//

import Foundation
import simd
import CoursonaCore

public enum DeltaCalibrator {
    public struct JawResult: Sendable, Equatable {
        public var scale: Float
        public var weight: Float
        public var regionVertices: Int
        /// 보정 전/후 턱 영역 RMS (m)
        public var rmsBefore: Float
        public var rmsAfter: Float
    }

    public static let minJawWeight: Float = 0.08
    public static let scaleRange: ClosedRange<Float> = 0.5...2.0

    public static func jawOpen(bundle: CaptureBundle, template t: BustTemplate, userPatch: [SIMD3<Float>],
                               alignments: [ShotKind: simd_float4x4]) -> JawResult? {
        let pc = t.patchCount
        guard let smile = bundle.shot(.smile), let F = alignments[.smile], let jaw = t.shapeDeltas[.jawOpen], jaw.count >= pc else { return nil }
        let raw = smile.meta.faceVertexArray
        guard raw.count == pc, userPatch.count == pc else { return nil }
        let wj = smile.meta.blendShapes[.jawOpen]
        guard wj >= minJawWeight else { return nil }

        let aligned = raw.map { Geometry.transformPoint(F, $0) }
        // 다른 셰이프 예측
        var other = [SIMD3<Float>](repeating: .zero, count: pc)
        for (shape, d) in t.shapeDeltas where shape != .jawOpen {
            let w = smile.meta.blendShapes[shape]
            guard w > 1e-4, d.count >= pc else { continue }
            for i in 0..<pc { other[i] += d[i] * w }
        }
        let maxJaw = (0..<pc).reduce(Float(0)) { max($0, simd_length(jaw[$1])) }
        guard maxJaw > 1e-5 else { return nil }
        var num: Float = 0, den: Float = 0, count = 0
        var before: Float = 0
        for i in 0..<pc where simd_length(jaw[i]) >= 0.3 * maxJaw {
            let obs = aligned[i] - userPatch[i] - other[i]
            let pred = jaw[i] * wj
            num += simd_dot(obs, pred); den += simd_length_squared(pred)
            before += simd_length_squared(obs - pred)
            count += 1
        }
        guard count >= 20, den > 1e-12 else { return nil }
        let r = min(scaleRange.upperBound, max(scaleRange.lowerBound, num / den))
        var after: Float = 0
        for i in 0..<pc where simd_length(jaw[i]) >= 0.3 * maxJaw {
            let obs = aligned[i] - userPatch[i] - other[i]
            after += simd_length_squared(obs - jaw[i] * wj * r)
        }
        return JawResult(scale: r, weight: wj, regionVertices: count,
                         rmsBefore: (before / Float(count)).squareRoot(), rmsAfter: (after / Float(count)).squareRoot())
    }

    /// 미소 컷 검증 잔차: 캡처 가중치로 변형한 패치(보정된 델타) vs 미소 컷 ARKit 메시(정렬) RMS (m).
    /// 함께 돌려주는 `neutral` 은 표정을 넣지 않은 패치의 같은 잔차 — 델타가 실제로 사진 쪽으로 가는지의 기준선.
    public static func smileResidual(bundle: CaptureBundle, template t: BustTemplate, identity: Identity,
                                     alignments: [ShotKind: simd_float4x4]) -> (deformed: Float, neutral: Float)? {
        let pc = t.patchCount
        guard let smile = bundle.shot(.smile), let F = alignments[.smile] else { return nil }
        let raw = smile.meta.faceVertexArray
        guard raw.count == pc, identity.positions.count >= pc else { return nil }
        let aligned = raw.map { Geometry.transformPoint(F, $0) }
        let neutral = Array(identity.positions[0..<pc])
        var deformed = neutral
        let deltas = identity.runtimeDeltas(template: t)
        for (shape, d) in deltas {
            let w = smile.meta.blendShapes[shape]
            guard w > 1e-4, d.count >= pc else { continue }
            for i in 0..<pc { deformed[i] += d[i] * w }
        }
        return (Geometry.rms(deformed, aligned), Geometry.rms(neutral, aligned))
    }
}
