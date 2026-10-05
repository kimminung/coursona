//
//  UserShapeDeltas.swift
//  CoursonaFit
//
//  F7(TechPRD §6.4, Tasks T-205, C3): 눈 감기·입 벌림 컷이 있으면 `eyeBlinkLeft/Right`·`jawOpen` **패치 델타를
//  사용자 것으로 직접 치환**한다. `DeltaCalibrator.jawOpen`(미소 컷에서 진폭만 추정)보다 정확하다 — 전용 컷이라
//  신호가 깨끗하고, 템플릿 델타의 "모양"이 아니라 사용자가 실제로 움직인 변위를 그대로 쓴다.
//  (모듈은 TechPRD 표에선 CoursonaFace 였지만 `DeltaCalibrator` 와 같은 패치-델타 계산이라 CoursonaFit 에 둔다.)
//
//  방법: 그 컷의 정렬·중립화 안 된 ARKit 패치를 정렬(F)만 적용 → 사용자 중립 패치와의 차이에서 **다른 셰이프의
//  예측(가중치 × 템플릿 델타)을 뺀다** → 목표 셰이프 하나의 가중치로 나눠 "1.0 기준" 델타로 되돌린다.
//

import Foundation
import simd
import CoursonaCore

public enum UserShapeDeltas {
    public static let minEyeBlinkWeight: Float = 0.5
    public static let minJawOpenWeight: Float = 0.3

    /// 한 셰이프의 패치 델타(1220)를 한 컷에서 직접 읽는다. 그 컷이 없거나 가중치가 너무 작으면 nil.
    public static func patchDelta(for shape: ArkitShape, shotKind: ShotKind, bundle: CaptureBundle, template t: BustTemplate,
                                  userPatch: [SIMD3<Float>], alignments: [ShotKind: simd_float4x4], minWeight: Float) -> [SIMD3<Float>]? {
        let pc = t.patchCount
        guard let shot = bundle.shot(shotKind), let F = alignments[shotKind] else { return nil }
        let raw = shot.meta.faceVertexArray
        guard raw.count == pc, userPatch.count == pc else { return nil }
        let w = shot.meta.blendShapes[shape]
        guard w >= minWeight else { return nil }
        let aligned = raw.map { Geometry.transformPoint(F, $0) }
        var other = [SIMD3<Float>](repeating: .zero, count: pc)
        for (s, d) in t.shapeDeltas where s != shape {
            let ow = shot.meta.blendShapes[s]
            guard ow > 1e-4, d.count >= pc else { continue }
            for i in 0..<pc { other[i] += d[i] * ow }
        }
        var delta = [SIMD3<Float>](repeating: .zero, count: pc)
        for i in 0..<pc { delta[i] = (aligned[i] - userPatch[i] - other[i]) / w }
        return delta
    }

    /// 눈 감기 컷 → `eyeBlinkLeft`·`eyeBlinkRight`, 입 벌림 컷 → `jawOpen`. 컷이 없으면 그 항목만 조용히 빠진다.
    public static func replacementDeltas(bundle: CaptureBundle, template t: BustTemplate, userPatch: [SIMD3<Float>],
                                         alignments: [ShotKind: simd_float4x4]) -> [ArkitShape: [SIMD3<Float>]] {
        var out: [ArkitShape: [SIMD3<Float>]] = [:]
        if let d = patchDelta(for: .eyeBlinkLeft, shotKind: .eyesClosed, bundle: bundle, template: t, userPatch: userPatch, alignments: alignments, minWeight: minEyeBlinkWeight) {
            out[.eyeBlinkLeft] = d
        }
        if let d = patchDelta(for: .eyeBlinkRight, shotKind: .eyesClosed, bundle: bundle, template: t, userPatch: userPatch, alignments: alignments, minWeight: minEyeBlinkWeight) {
            out[.eyeBlinkRight] = d
        }
        if let d = patchDelta(for: .jawOpen, shotKind: .mouthOpen, bundle: bundle, template: t, userPatch: userPatch, alignments: alignments, minWeight: minJawOpenWeight) {
            out[.jawOpen] = d
        }
        return out
    }
}
