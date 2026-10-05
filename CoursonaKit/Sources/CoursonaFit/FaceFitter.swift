//
//  FaceFitter.swift
//  CoursonaFit
//
//  캡처 번들 → Identity (TechPRD §6.4). 단계:
//   1–2. `FacePatchSolver` — 정렬·중립화·컷 평균·스케일 s·눈알(눈꺼풀 링)           (T-301 · T-302)
//   3.   `HeadPropagator`  — 패치 치환 + 전역 유사변환 + 국소 잔차 RBF(바이하모닉 r³) × 경계 감쇠 + 목 감쇠 + 어깨 스케일 + 대칭  (T-303)
//   4.   `SilhouetteFitter` — 깊이 포인트 클라우드로 두상·귀·턱 밑 정점을 법선 방향으로 당김 (≤ 12 mm, GN 5회, 라플라시안 λ 0.1)   (T-304)
//   5.   `DeltaCalibrator` — jawOpen 진폭(미소 컷), 미소 검증 잔차                     (T-305 · T-308)
//   희소 번들(사진만)은 `SparseFitter` 로 간다                                          (T-306)
//
//  두상 전파 = 전역 유사변환(패치 Procrustes, 스케일 포함) + 국소 잔차 RBF × 경계 거리 감쇠(σ, 기본 5 cm).
//  — r³ 커널은 멀리서 선형으로 자라 뒤통수를 망치므로 잔차만 전파하고 감쇠한다(1차 측정: 감쇠 없이 중앙값 6 mm).
//

import Foundation
import simd
import CoursonaCore

public struct FitOptions: Sendable, Equatable {
    /// RBF 중심: 패치 경계 최대 개수, 내부 샘플 개수
    public var maxBoundaryCenters = 200
    public var interiorCenters = 100
    /// 좌우 대칭 보정 비율 (0 = 사용자 비대칭 그대로, 1 = 완전 대칭)
    public var symmetry: Float = 0.7
    /// 목 감쇠 구간 (y, m): 위 = 1, 아래 = 0
    public var neckFalloffTop: Float = 0.30
    public var neckFalloffBottom: Float = 0.22
    /// 국소 잔차 전파의 경계 거리 감쇠 σ (m). 0 이면 감쇠 없음(순수 RBF 외삽).
    public var propagationFalloff: Float = 0.05
    public var rbfLambda: Double = 0
    /// T-304 실루엣 맞춤
    public var silhouette = SilhouetteOptions()
    /// T-305 jawOpen 진폭 보정 (미소 컷)
    public var calibrateJawOpen = true
    /// F7(C3, T-205): 눈 감기·입 벌림 컷이 있으면 `eyeBlinkLeft/Right`·`jawOpen` 패치 델타를 직접 치환한다.
    public var calibrateUserShapes = true
    public init() {}
}

public enum FitError: Error, LocalizedError {
    case noNeutralShots
    case vertexCountMismatch(expected: Int, got: Int)
    case procrustesFailed(ShotKind)
    case rbfFailed
    case sparseBundle
    case sparseInsufficientLandmarks(Int)
    public var errorDescription: String? {
        switch self {
        case .noNeutralShots: "중립 컷이 없습니다 (정면·좌·우·위 중 하나 이상 필요)"
        case .vertexCountMismatch(let e, let g): "얼굴 정점 수가 다릅니다 (템플릿 \(e), 캡처 \(g))"
        case .procrustesFailed(let k): "\(k.title) 컷 정합에 실패했습니다"
        case .rbfFailed: "두상 전파(RBF) 풀이에 실패했습니다"
        case .sparseBundle: "사진만으로 만든 희소 번들(sparse)입니다 — ARKit 1220 정점이 없어 밀집 피팅을 할 수 없습니다"
        case .sparseInsufficientLandmarks(let n): "희소 피팅에 필요한 랜드마크가 부족합니다 (\(n)개, 눈 꼬리 4 + 코끝·입꼬리·턱 중 \(SparseFitter.minLandmarks)개 이상 필요)"
        }
    }
}

public enum FaceFitter {
    /// 번들 전체 피팅. 희소 번들(사진 폴백)은 `SparseFitter` 로 간다.
    public static func fit(bundle: CaptureBundle, template t: BustTemplate, options: FitOptions = FitOptions()) throws -> Identity {
        if bundle.meta.sparse || (!bundle.shots.isEmpty && bundle.shots.allSatisfy({ $0.meta.isSparse })) {
            return try SparseFitter.fit(bundle: bundle, template: t, options: options)
        }
        let start = Date()

        // 1–2) 패치
        let patch = try FacePatchSolver.solve(bundle: bundle, template: t)

        // 3) 패치 치환 + 두상 전파
        var (positions, lambda, pivot) = try HeadPropagator.propagate(template: t, userPatch: patch.userPatch, scale: patch.scale, options: options)

        // 4) 실루엣
        var silhouette: SilhouetteResult? = nil
        if options.silhouette.enabled {
            silhouette = SilhouetteFitter.fit(positions: &positions, template: t, bundle: bundle, alignments: patch.alignments, options: options)
        }

        // 5) 델타 보정 (jawOpen 진폭)
        var patchDeltas: [ArkitShape: [SIMD3<Float>]] = [:]
        var shapeScales: [ArkitShape: Float] = [:]
        var jaw: DeltaCalibrator.JawResult? = nil
        if options.calibrateJawOpen, let j = DeltaCalibrator.jawOpen(bundle: bundle, template: t, userPatch: patch.userPatch, alignments: patch.alignments) {
            jaw = j
            shapeScales[.jawOpen] = j.scale
            if let d = t.shapeDeltas[.jawOpen], d.count >= t.patchCount {
                patchDeltas[.jawOpen] = (0..<t.patchCount).map { d[$0] * j.scale }
            }
        }
        // F7(C3, T-205): 눈 감기·입 벌림 컷이 있으면 더 정확한 직접 치환으로 덮어쓴다(미소 컷 기반 jawOpen 진폭보다 우선).
        if options.calibrateUserShapes {
            for (shape, d) in UserShapeDeltas.replacementDeltas(bundle: bundle, template: t, userPatch: patch.userPatch, alignments: patch.alignments) {
                patchDeltas[shape] = d
            }
        }

        var q = FitQuality(patchRMS: patch.worstRMS, patchRMSPerShot: patch.perShotRMS, silhouetteResidualMedian: silhouette?.residualMedian,
                           rbfLambda: lambda, rbfPivotRatio: pivot, shotsUsed: patch.shotsUsed, elapsedSeconds: 0)
        q.method = "dense"
        q.eyeFit = patch.eyeFit
        q.jawOpenScale = jaw?.scale
        if let s = silhouette {
            q.silhouetteVertices = s.matchedVertices
            q.silhouettePoints = s.points
            q.silhouetteResidualP90 = s.residualP90
            if !s.depthOffsets.isEmpty { q.depthOffsetPerShot = Dictionary(uniqueKeysWithValues: s.depthOffsets.map { ($0.key.rawValue, $0.value) }) }
        }
        var identity = Identity(templateID: t.manifest.id, templateVersion: t.manifest.version, positions: positions, scale: patch.scale,
                                eyeCenterL: patch.eyeCenterL, eyeCenterR: patch.eyeCenterR, eyeRadius: patch.eyeRadius,
                                patchDeltas: patchDeltas, shapeScales: shapeScales, quality: q)
        if let smile = DeltaCalibrator.smileResidual(bundle: bundle, template: t, identity: identity, alignments: patch.alignments) {
            q.smileResidualRMS = smile.deformed
            q.smileNeutralRMS = smile.neutral
        }
        q.elapsedSeconds = Date().timeIntervalSince(start)
        identity.quality = q
        return identity
    }

    /// 컷별 **얼굴 좌표 → 템플릿 좌표** 강체 변환 (회전 + 눈 중점 정렬 이동).
    /// `fit` 의 1단계와 같은 계산이다. 텍스처 투영(M4)·미소 검증 렌더(T-308)가 캡처 카메라를 템플릿 공간으로 옮길 때 쓴다 —
    /// 캡처마다 머리 위치가 다르므로 이 변환 없이는 모든 컷이 어긋난 곳에 투영된다.
    /// 희소(사진 폴백) 번들은 밀집 ARKit 메시가 없어 `FacePatchSolver.alignment`를 못 쓰므로 `SparseFitter`의 컷별 정렬을 쓴다 —
    /// 미소 컷도 포함한다(모양 피팅에는 안 쓰지만 텍스처 투영에는 쓴다, `SparseFitter.fit` 참고).
    public static func alignments(bundle: CaptureBundle, template t: BustTemplate) -> [ShotKind: simd_float4x4] {
        var out: [ShotKind: simd_float4x4] = [:]
        for shot in bundle.shots {
            if shot.meta.isSparse {
                if let c = SparseFitter.correspondences(shot: shot, template: t) { out[shot.kind] = c.alignment }
            } else if let F = FacePatchSolver.alignment(raw: shot.meta.faceVertexArray, template: t) {
                out[shot.kind] = F
            }
        }
        return out
    }
}

/// 두상 전파: 전역 유사변환 + 국소 잔차 RBF(경계 거리 감쇠) + 목 감쇠 + 어깨 스케일 + 대칭.
public enum HeadPropagator {
    public static func propagate(template t: BustTemplate, userPatch: [SIMD3<Float>], scale s: Float, options: FitOptions)
        throws -> (positions: [SIMD3<Float>], lambda: Double, pivotRatio: Double) {
        let pc = t.patchCount
        precondition(userPatch.count == pc)
        let templatePatch = Array(t.patchPositions)

        // (a) 전역 유사변환: 템플릿 패치 → 사용자 패치
        let S = Procrustes.fit(source: templatePatch, target: userPatch, allowScale: true) ?? .identity
        let shoulders = Set(t.manifest.group(.shoulders))
        let neck = Set(t.manifest.group(.neck))
        var base = t.positions
        for i in base.indices {
            if shoulders.contains(i) {
                base[i] = SIMD3(base[i].x * s, base[i].y, base[i].z * s)     // 어깨: 가로·앞뒤 스케일만
            } else if neck.contains(i) {
                let w = neckWeight(y: base[i].y, options: options)
                let sc = SIMD3(base[i].x * s, base[i].y, base[i].z * s)
                base[i] = S.apply(base[i]) * w + sc * (1 - w)
            } else {
                base[i] = S.apply(base[i])
            }
        }

        // (b) 국소 잔차 RBF
        let residual = (0..<pc).map { userPatch[$0] - base[$0] }
        var boundary = t.patchBoundaryVertices()
        if boundary.count > options.maxBoundaryCenters {
            let stride = Double(boundary.count) / Double(options.maxBoundaryCenters)
            boundary = (0..<options.maxBoundaryCenters).map { boundary[Int(Double($0) * stride)] }
        }
        let bset = Set(boundary)
        var interior: [Int] = []
        if options.interiorCenters > 0 {
            let stride = max(1, pc / options.interiorCenters)
            var i = stride / 2
            while i < pc && interior.count < options.interiorCenters { if !bset.contains(i) { interior.append(i) }; i += stride }
        }
        let centerIDs = boundary + interior
        let centers = centerIDs.map { base[$0] }
        guard let rbf = BiharmonicRBF(centers: centers, values: centerIDs.map { residual[$0] }, lambda: options.rbfLambda) else { throw FitError.rbfFailed }
        let boundaryPts = boundary.map { base[$0] }
        let sigma = options.propagationFalloff

        var d = [SIMD3<Float>](repeating: .zero, count: base.count)
        for i in pc..<base.count where !shoulders.contains(i) {
            var v = rbf.evaluate(base[i])
            if sigma > 0 {
                var dmin = Float.greatestFiniteMagnitude
                for b in boundaryPts { dmin = min(dmin, simd_length_squared(base[i] - b)) }
                v *= exp(-dmin / (sigma * sigma))
            }
            if neck.contains(i) { v *= neckWeight(y: base[i].y, options: options) }
            d[i] = v
        }
        // (c) 좌우 대칭 보정 (패치 밖만)
        let sym = t.manifest.symmetryMap
        if options.symmetry > 0, sym.count == base.count {
            var dd = d
            for i in pc..<base.count {
                let j = Int(sym[i])
                guard j >= 0, j < base.count, j >= pc else { continue }
                let mirrored = SIMD3(-d[j].x, d[j].y, d[j].z)
                dd[i] = (d[i] + mirrored) / 2 * options.symmetry + d[i] * (1 - options.symmetry)
            }
            d = dd
        }
        var out = base
        for i in pc..<out.count { out[i] += d[i] }
        for i in 0..<pc { out[i] = userPatch[i] }
        return (out, rbf.lambda, rbf.pivotRatio)
    }

    /// 목 감쇠 가중치: `neckFalloffTop` 위 = 1, `neckFalloffBottom` 아래 = 0 (smoothstep).
    public static func neckWeight(y: Float, options: FitOptions) -> Float {
        smooth((y - options.neckFalloffBottom) / max(1e-4, options.neckFalloffTop - options.neckFalloffBottom))
    }

    static func smooth(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
}
