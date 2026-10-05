//
//  FacePatchSolver.swift
//  CoursonaFit
//
//  T-301 · T-302: 컷별 강체 정렬(Procrustes 회전 + 눈 중점 이동) → 표정 중립화(− Σ 델타 × 가중치) → 컷 평균 → 패치 치환용 사용자 패치,
//  스케일 s(눈 간격 비), 눈알 중심·반지름(눈꺼풀 링 피팅).
//
//  좌표 규약: 사용자 패치는 **눈 중심(안·바깥 꼬리 평균)의 중점이 템플릿 눈 중점에 오도록** 강체 정렬한다(치수는 사용자 것 유지).
//
//  눈알 추정: 눈꺼풀 루프(template.json `patchLoops.eye_left/right`, 24점)는 거의 한 평면의 고리라 "고리를 지나는 구" 는 한 매개변수만큼
//  자유롭다(ill-posed). 그래서 ① 사전값(반지름 = manifest × s, 중심 = 고리 중심에서 법선 안쪽으로 √(r² − ρ²)) 을 먼저 두고,
//  ② 대수적 구 피팅 결과가 사전값과 모순되지 않을 때만(반지름 0.7–1.35 배, 중심 0.6 r 이내) 절반씩 섞는다. 어느 쪽을 썼는지 `eyeFit` 에 남긴다.
//

import Foundation
import simd
import CoursonaCore

public struct PatchSolution: Sendable {
    /// 중립화·평균된 사용자 패치 (템플릿 공간, 1220)
    public var userPatch: [SIMD3<Float>]
    /// 컷별 **얼굴 좌표 → 템플릿 좌표** 강체 변환 (미소 컷 포함, 정렬 실패 컷은 없음)
    public var alignments: [ShotKind: simd_float4x4]
    public var perShotRMS: [String: Float]
    public var worstRMS: Float
    /// 사용자 눈 간격 / 템플릿 눈 간격
    public var scale: Float
    public var eyeCenterL: SIMD3<Float>
    public var eyeCenterR: SIMD3<Float>
    public var eyeRadius: Float
    /// "ring+ring" · "prior+ring" · "landmark" · "manifest"
    public var eyeFit: String
    public var shotsUsed: Int
}

public enum FacePatchSolver {
    /// 중립 컷(정면·좌·우·위)으로 사용자 패치를 푼다. 미소 컷은 정렬만 계산한다(검증·jawOpen 보정용).
    public static func solve(bundle: CaptureBundle, template t: BustTemplate) throws -> PatchSolution {
        let pc = t.patchCount
        let templatePatch = Array(t.patchPositions)
        let shots = bundle.neutralShots
        guard !shots.isEmpty else { throw FitError.noNeutralShots }
        guard !bundle.meta.sparse, !shots.allSatisfy({ $0.meta.isSparse }) else { throw FitError.sparseBundle }

        // 1) 컷별 정렬 + 중립화
        var aligned: [[SIMD3<Float>]] = []
        var alignments: [ShotKind: simd_float4x4] = [:]
        for shot in bundle.shots {
            let raw = shot.meta.faceVertexArray
            guard raw.count == pc else {
                if shot.kind.isNeutralRequired { throw FitError.vertexCountMismatch(expected: pc, got: raw.count) }
                continue
            }
            guard let F = alignment(raw: raw, template: t) else {
                if shot.kind.isNeutralRequired { throw FitError.procrustesFailed(shot.kind) }
                continue
            }
            alignments[shot.kind] = F
            guard shot.kind.isNeutralRequired else { continue }
            var p = raw.map { Geometry.transformPoint(F, $0) }
            // 표정 제거: 템플릿 델타 × 그 컷의 가중치
            for (shape, deltas) in t.shapeDeltas {
                let w = shot.meta.blendShapes[shape]
                guard w > 1e-4, deltas.count >= pc else { continue }
                for i in 0..<pc { p[i] -= deltas[i] * w }
            }
            aligned.append(p)
        }
        guard !aligned.isEmpty else { throw FitError.noNeutralShots }

        // 2) 컷 평균
        var userPatch = [SIMD3<Float>](repeating: .zero, count: pc)
        for a in aligned { for i in 0..<pc { userPatch[i] += a[i] } }
        for i in 0..<pc { userPatch[i] /= Float(aligned.count) }
        var perShot: [String: Float] = [:]
        var worst: Float = 0
        let neutral = shots.filter { alignments[$0.kind] != nil }
        for (k, a) in aligned.enumerated() where k < neutral.count {
            let r = Geometry.rms(a, userPatch)
            perShot[neutral[k].kind.rawValue] = r
            worst = max(worst, r)
        }

        // 3) 스케일
        let s = eyeSpacing(userPatch, manifest: t.manifest) / max(1e-4, eyeSpacing(templatePatch, manifest: t.manifest))

        // 4) 눈알
        let eyes = estimateEyes(userPatch: userPatch, template: t, scale: s)
        return PatchSolution(userPatch: userPatch, alignments: alignments, perShotRMS: perShot, worstRMS: worst, scale: s,
                             eyeCenterL: eyes.left, eyeCenterR: eyes.right, eyeRadius: eyes.radius, eyeFit: eyes.fit, shotsUsed: aligned.count)
    }

    /// 얼굴 좌표(ARKit 메시) → 템플릿 좌표 강체 변환: Procrustes 회전(스케일은 버림) + 눈 중점 정렬 이동.
    public static func alignment(raw: [SIMD3<Float>], template t: BustTemplate) -> simd_float4x4? {
        let templatePatch = Array(t.patchPositions)
        guard raw.count == templatePatch.count, let T = Procrustes.fit(source: raw, target: templatePatch, allowScale: true) else { return nil }
        let rotated = raw.map { T.rotation.act($0) }
        let shift = eyeMidpoint(templatePatch, manifest: t.manifest) - eyeMidpoint(rotated, manifest: t.manifest)
        var m = simd_float4x4(T.rotation)
        m.columns.3 = SIMD4(shift, 1)
        return m
    }

    // MARK: 눈

    public struct EyeEstimate: Sendable { public var left: SIMD3<Float>; public var right: SIMD3<Float>; public var radius: Float; public var fit: String }

    public static func estimateEyes(userPatch: [SIMD3<Float>], template t: BustTemplate, scale s: Float) -> EyeEstimate {
        let m = t.manifest
        let r0 = m.eyeRadius * s
        let pc = userPatch.count
        func ring(_ name: String) -> [SIMD3<Float>]? {
            guard let ids = m.patchLoops[name], ids.count >= 6, ids.allSatisfy({ $0 >= 0 && $0 < pc }) else { return nil }
            return ids.map { userPatch[$0] }
        }
        func fromRing(_ loop: [SIMD3<Float>]) -> (SIMD3<Float>, Float, String) {
            let c = loop.reduce(.zero, +) / Float(loop.count)
            // 고리 법선: 얼굴 바깥(+Z)을 향하게
            var n = SphereFit.loopNormal(loop) ?? SIMD3(0, 0, 1)
            if n.z < 0 { n = -n }
            let rho = min(SphereFit.loopRadius(loop, normal: n), r0 * 0.9)
            let depth = (r0 * r0 - rho * rho).squareRoot()
            let prior = c - n * depth
            if let sf = SphereFit.algebraic(loop), sf.radius > 0.7 * r0, sf.radius < 1.35 * r0, simd_length(sf.center - prior) < 0.6 * r0 {
                return ((sf.center + prior) / 2, (sf.radius + r0) / 2, "ring")
            }
            return (prior, r0, "prior")
        }
        if let L = ring("eye_left"), let R = ring("eye_right") {
            let (cl, rl, fl) = fromRing(L), (cr, rr, fr) = fromRing(R)
            return EyeEstimate(left: cl, right: cr, radius: (rl + rr) / 2, fit: "\(fl)+\(fr)")
        }
        if let (oL, iL, iR, oR) = eyeLandmarks(m, count: pc) {
            // 눈꺼풀 표면 중심에서 안쪽(−Z)으로 반지름의 0.85 만큼 (각막이 표면 바로 뒤)
            let cL = (userPatch[oL] + userPatch[iL]) / 2 - SIMD3(0, 0, r0 * 0.85)
            let cR = (userPatch[oR] + userPatch[iR]) / 2 - SIMD3(0, 0, r0 * 0.85)
            return EyeEstimate(left: cL, right: cR, radius: r0, fit: "landmark")
        }
        return EyeEstimate(left: m.eyeCenterL * s, right: m.eyeCenterR * s, radius: r0, fit: "manifest")
    }

    // MARK: 랜드마크 유틸 (FaceFitter 와 공유)

    static func eyeLandmarks(_ m: TemplateManifest, count: Int) -> (Int, Int, Int, Int)? {
        guard let oL = m.landmark(.eyeLeftOuter), let iL = m.landmark(.eyeLeftInner), let iR = m.landmark(.eyeRightInner), let oR = m.landmark(.eyeRightOuter),
              [oL, iL, iR, oR].allSatisfy({ $0 < count }) else { return nil }
        return (oL, iL, iR, oR)
    }

    /// 눈 중점 (랜드마크 없으면 패치 무게중심).
    static func eyeMidpoint(_ patch: [SIMD3<Float>], manifest m: TemplateManifest) -> SIMD3<Float> {
        guard let (oL, iL, iR, oR) = eyeLandmarks(m, count: patch.count) else { return patch.reduce(.zero, +) / Float(max(1, patch.count)) }
        return (patch[oL] + patch[iL] + patch[iR] + patch[oR]) / 4
    }

    /// 랜드마크(눈 안/바깥 꼬리)로 눈 간격. 랜드마크가 없으면 manifest 의 눈 중심 간격.
    static func eyeSpacing(_ patch: [SIMD3<Float>], manifest m: TemplateManifest) -> Float {
        guard let (oL, iL, iR, oR) = eyeLandmarks(m, count: patch.count) else { return simd_length(m.eyeCenterL - m.eyeCenterR) }
        let cL = (patch[oL] + patch[iL]) / 2, cR = (patch[oR] + patch[iR]) / 2
        return simd_length(cL - cR)
    }
}
