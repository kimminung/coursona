//
//  SparseFitter.swift
//  CoursonaFit
//
//  T-306 희소 폴백: 사진 + Vision 키포인트(TrueDepth 없음 · Mac 카메라 · 사진 파일, T-205) → Identity.
//  대응: `keyPoints2D`(template.json 랜드마크 이름과 같은 8점: 눈 꼬리 4 · 코끝 · 입꼬리 2 · 턱끝) + (있으면) `visionIndices` 로 이어진 점들.
//  실제 배포 템플릿은 `visionIndices` 가 비어 있어 컷당 8점이다 — 그래서 **컷 1장이 아니라 번들의 중립 컷(정면·좌·우·위) 전부**를 쓴다.
//
//  기하 (컷 하나, `correspondences`):
//   1. 템플릿을 카메라 앞에 둔다 — 회전은 그 컷의 자세(faceTransform), 위치는 **템플릿 눈 중점이 관측 눈 중점 픽셀의 광선 위**에
//      오도록, 깊이는 z = f · (템플릿 눈 간격 · cos yaw) / (관측 눈 간격 px) 로 가정한다(원근 보정 반복으로 다듬음).
//      이걸로 "컷 → 템플릿" 변환(`F`, `FacePatchSolver.alignment` 와 같은 계약: 얼굴 좌표 → 템플릿 좌표)이 나온다 —
//      텍스처 투영(M4)·미소 검증이 그대로 쓸 수 있다(`FaceFitter.alignments`).
//   2. 각 랜드마크 픽셀의 **광선**(카메라 원점 → 그 픽셀 방향, 템플릿 공간)만 남긴다. 한 장의 사진은 깊이를 모르니 그 랜드마크가
//      "이 광선 위 어딘가" 라는 것만 안다 — 딱 그만큼만 쓴다.
//  3컷 이상이 같은 정점을 보면(`fit`), 광선들을 3×3 최소제곱(가까운 두 직선 교차점)으로 모아 **진짜 깊이**를 복원한다
//      (단일 컷만 있으면 템플릿의 기존 위치를 그 광선 방향으로만 당겨 오늘까지의 동작과 같아진다). 평균이 아니라 삼각측량인 이유:
//      변위를 평균 내면 정면 컷의 "광선 방향 성분 0" 이 측면 컷의 깊이 정보를 희석해 버린다.
//   3. 모인 정점별 변위를 3D 바이하모닉 RBF(`BiharmonicRBF`)로 두상 전체에 전파. 랜드마크에서 멀어질수록 감쇠(σ 8 cm),
//      목 감쇠, 좌우 대칭 보정(options.symmetry — 비대칭은 대부분 잡음).
//   4. 눈알 = manifest 중심을 같은 워프로 옮긴 것, 반지름 = manifest.
//  스케일은 여전히 1 로 고정한다 — 여러 컷이어도 기준 베이스라인이 없어 절대 크기는 못 잰다(63 mm 동공 거리 가정과 같은 사전값일 뿐).
//

import Foundation
import simd
import CoursonaCore

public enum SparseFitter {
    /// 랜드마크 감쇠 σ (m)
    public static let falloffSigma: Float = 0.08
    public static let minLandmarks = 5
    /// 정점별 삼각측량에서 템플릿 위치를 향한 사전항 가중치 (컷 1장이면 오늘까지의 "광선 방향만 모름" 동작과 같아진다).
    static let triangulationPrior: Float = 1e-3
    /// 광선-법선 내적이 이보다 작으면(거의 옆에서 보는 관측) 그 컷의 그 랜드마크는 버린다.
    static let minViewWeight: Float = 0.2
    /// 정점별 삼각측량 변위 상한(m). 눈 간격 추정이 흔들리거나(블러·반사·가려짐) 컷 간 자세가 어긋나면 `A⁻¹b` 가
    /// 템플릿 표면에서 수십 cm~수 m 떨어진 값을 내놓을 수 있다 — RBF 중심값이 그만큼 크면 주변까지 뾰족하게 당겨
    /// 흉상에 바늘 같은 돌기가 생긴다(겹침 의심 폭증과 함께 관측됨). `SilhouetteFitter.maxPull` 과 같은 이유의 clamp.
    static let maxLandmarkDisplacement: Float = 0.03

    /// 컷 하나의 자세 정렬 + 랜드마크 광선 (템플릿 공간). 여러 컷을 합칠 때 쓴다.
    struct ShotCorrespondence {
        var kind: ShotKind
        /// 얼굴 좌표(ARKit 메시와 같은 자리) → 템플릿 좌표. `FacePatchSolver.alignment` 와 같은 계약.
        var alignment: simd_float4x4
        /// 카메라 원점(템플릿 공간)
        var cameraOriginT: SIMD3<Float>
        /// (정점, 광선 방향 단위벡터, 랜드마크 이름)
        var rays: [(vertex: Int, dir: SIMD3<Float>, name: String)]
        var reprojRMSpx: Float
        var intrinsicsEstimated: Bool
    }

    /// 컷 하나에서 정렬 + 랜드마크 광선을 계산한다. 키포인트가 모자르면 nil.
    static func correspondences(shot: CaptureShot, template t: BustTemplate) -> ShotCorrespondence? {
        let m = t.manifest
        var pixels: [(vertex: Int, px: SIMD2<Float>, name: String)] = []
        for name in LandmarkName.allCases {
            guard let v = m.landmark(name), v < t.vertexCount, let px = shot.meta.keyPoint(name) else { continue }
            pixels.append((v, px, name.rawValue))
        }
        let lm = shot.meta.landmarkArray
        for (name, vi) in m.visionIndices where vi >= 0 && vi < lm.count {
            guard let v = m.landmarks[name], v < t.vertexCount, !pixels.contains(where: { $0.vertex == v }) else { continue }
            pixels.append((v, lm[vi], name))
        }
        guard pixels.count >= minLandmarks,
              let eL = shot.meta.keyPoint(.eyeLeftOuter), let eLi = shot.meta.keyPoint(.eyeLeftInner),
              let eR = shot.meta.keyPoint(.eyeRightOuter), let eRi = shot.meta.keyPoint(.eyeRightInner) else { return nil }

        // 1) 템플릿 → 카메라 변환 (오늘까지의 단일 컷 코드와 동일한 눈 중점 깊이 추정 + 원근 보정)
        let K = shot.meta.intrinsics
        let faceInCamera = shot.cameraTransform.inverse * shot.faceTransform
        let R = simd_quatf(faceInCamera)
        let templatePatch = Array(t.patchPositions)
        let eyeMidT = FacePatchSolver.eyeMidpoint(templatePatch, manifest: m)
        let eyeSpacingT = FacePatchSolver.eyeSpacing(templatePatch, manifest: m)
        let eyeLpx = (eL + eLi) / 2, eyeRpx = (eR + eRi) / 2
        let dpx = max(1, simd_length(eyeLpx - eyeRpx))
        let obsMid = (eyeLpx + eyeRpx) / 2
        let (yaw, _) = Geometry.faceYawPitch(faceInCamera: faceInCamera)
        var z = K.fx * eyeSpacingT * max(0.2, cos(yaw * .pi / 180)) / dpx
        var eyeMidCam = K.unproject(obsMid, depth: z)
        func toCamera(_ p: SIMD3<Float>) -> SIMD3<Float> { R.act(p - eyeMidT) + eyeMidCam }
        if let oL = m.landmark(.eyeLeftOuter), let iL = m.landmark(.eyeLeftInner), let iR = m.landmark(.eyeRightInner), let oR = m.landmark(.eyeRightOuter) {
            for _ in 0..<4 {
                guard let pOL = K.project(toCamera(t.positions[oL])), let pIL = K.project(toCamera(t.positions[iL])),
                      let pIR = K.project(toCamera(t.positions[iR])), let pOR = K.project(toCamera(t.positions[oR])) else { break }
                let tL = (pOL + pIL) / 2, tR = (pOR + pIR) / 2
                let dT = max(1, simd_length(tL - tR)), midT = (tL + tR) / 2
                z *= dT / dpx
                let shift = obsMid - midT
                eyeMidCam = K.unproject(K.project(eyeMidCam).map { $0 + shift } ?? obsMid, depth: z)
            }
        }

        // 2) 정렬 F = (카메라 → 템플릿) ∘ (얼굴 → 카메라). 소비자(TextureBuilder/SmileVerification)는
        //    M = F · faceTransform⁻¹ · cameraTransform 을 "카메라 → 템플릿" 으로 쓰는데, 정의상 정확히 이 조합이다.
        let Rinv = R.inverse
        let cameraOriginT = eyeMidT - Rinv.act(eyeMidCam)
        var toTemplate4x4 = simd_float4x4(Rinv)
        toTemplate4x4.columns.3 = SIMD4(cameraOriginT, 1)
        let F = toTemplate4x4 * faceInCamera

        // 3) 랜드마크 광선 (템플릿 공간 방향 단위벡터) + 재투영 오차(진단용)
        var rays: [(vertex: Int, dir: SIMD3<Float>, name: String)] = []
        var reproj: Float = 0, reprojN = 0
        for (v, px, name) in pixels {
            let camDir = K.unproject(px, depth: 1)
            guard let dir = safeNormalize(Rinv.act(camDir)) else { continue }
            rays.append((v, dir, name))
            if let q = K.project(toCamera(t.positions[v])) { reproj += simd_length_squared(q - px); reprojN += 1 }
        }
        guard rays.count >= minLandmarks else { return nil }
        let reprojRMSpx = reprojN > 0 ? (reproj / Float(reprojN)).squareRoot() : 0
        return ShotCorrespondence(kind: shot.kind, alignment: F, cameraOriginT: cameraOriginT, rays: rays,
                                  reprojRMSpx: reprojRMSpx, intrinsicsEstimated: shot.meta.intrinsicsEstimated == true)
    }

    public static func fit(bundle: CaptureBundle, template t: BustTemplate, options: FitOptions = FitOptions()) throws -> Identity {
        let start = Date()
        let m = t.manifest
        // 모양 피팅은 중립 컷만 (미소 컷은 블렌드셰이프가 없어 표정이 그대로 노이즈가 된다) — 텍스처용 정렬은 FaceFitter.alignments 가 전체 컷에 대해 따로 만든다.
        let perShot = bundle.neutralShots.compactMap { correspondences(shot: $0, template: t) }
        guard !perShot.isEmpty else { throw FitError.sparseInsufficientLandmarks(0) }

        // 정점별로 모든 컷의 광선을 모아 3×3 최소제곱 삼각측량 (평균이 아니라 "가까운 직선들의 교점").
        // 컷이 1개뿐이면 사전항(triangulationPrior)이 광선 방향 성분을 템플릿의 기존 위치로 채워, 오늘까지의 단일 컷 동작과 같아진다.
        struct Term { var dir: SIMD3<Float>; var origin: SIMD3<Float>; var weight: Float }
        var byVertex: [Int: (name: String, terms: [Term])] = [:]
        let templateNormals = Geometry.vertexNormals(positions: t.positions, indices: t.indices)
        for corr in perShot {
            for (v, dir, name) in corr.rays {
                guard v < templateNormals.count else { continue }
                let w = max(0, simd_dot(templateNormals[v], -dir))
                guard w >= minViewWeight else { continue }
                byVertex[v, default: (name, [])].terms.append(Term(dir: dir, origin: corr.cameraOriginT, weight: w))
            }
        }
        var centers: [SIMD3<Float>] = [], values: [SIMD3<Float>] = [], names: [String] = []
        for (v, entry) in byVertex {
            guard !entry.terms.isEmpty else { continue }
            let P = t.positions[v]
            var A = Self.identity3 * triangulationPrior
            var b = P * triangulationPrior
            for term in entry.terms {
                let Q = Self.identity3 - Self.outer(term.dir, term.dir)
                A += Q * term.weight
                b += (Q * term.origin) * term.weight
            }
            let X = A.inverse * b
            var disp = X - P
            let dl = simd_length(disp)
            if dl > maxLandmarkDisplacement { disp *= maxLandmarkDisplacement / dl }
            centers.append(P); values.append(disp); names.append(entry.name)
        }
        guard centers.count >= minLandmarks else { throw FitError.sparseInsufficientLandmarks(centers.count) }

        // 3b) 좌우 대칭 보정 (한 장/적은 장수 사진의 비대칭은 대부분 Vision 잡음). 좌/우 짝은 거울 평균, 가운데 랜드마크는 x 성분을 줄인다.
        if options.symmetry > 0 {
            let s = options.symmetry
            var out = values
            for (i, name) in names.enumerated() {
                if name.contains("_left") || name.contains("_right") {
                    let partner = name.contains("_left") ? name.replacingOccurrences(of: "_left", with: "_right") : name.replacingOccurrences(of: "_right", with: "_left")
                    if let j = names.firstIndex(of: partner) {
                        let mirrored = SIMD3(-values[j].x, values[j].y, values[j].z)
                        out[i] = (values[i] + mirrored) / 2 * s + values[i] * (1 - s)
                    }
                } else {
                    out[i].x *= (1 - s)
                }
            }
            values = out
        }

        // 4) 3D RBF 전파 (+ 감쇠 · 목)
        guard let rbf = BiharmonicRBF(centers: centers, values: values, lambda: options.rbfLambda) else { throw FitError.rbfFailed }
        let shoulders = Set(t.manifest.group(.shoulders))
        let neck = Set(t.manifest.group(.neck))
        let sigma2 = falloffSigma * falloffSigma
        func warp(_ p: SIMD3<Float>) -> SIMD3<Float> {
            var dmin = Float.greatestFiniteMagnitude
            for c in centers { dmin = min(dmin, simd_length_squared(p - c)) }
            return rbf.evaluate(p) * exp(-dmin / sigma2)
        }
        var d = [SIMD3<Float>](repeating: .zero, count: t.vertexCount)
        for i in 0..<t.vertexCount where !shoulders.contains(i) {
            var v = warp(t.positions[i])
            if neck.contains(i) { v *= HeadPropagator.neckWeight(y: t.positions[i].y, options: options) }
            d[i] = v
        }
        var positions = t.positions
        for i in positions.indices { positions[i] += d[i] }

        // 5) 눈알
        let eyeL = m.eyeCenterL + warp(m.eyeCenterL), eyeR = m.eyeCenterR + warp(m.eyeCenterR)

        var q = FitQuality(patchRMS: 0, patchRMSPerShot: [:], silhouetteResidualMedian: nil,
                           rbfLambda: rbf.lambda, rbfPivotRatio: rbf.pivotRatio, shotsUsed: perShot.count, elapsedSeconds: Date().timeIntervalSince(start))
        q.method = "sparse"
        q.landmarksUsed = centers.count
        q.eyeFit = "manifest"
        let maxDisp = values.reduce(Float(0)) { max($0, simd_length($1)) }
        let avgReproj = perShot.map(\.reprojRMSpx).reduce(0, +) / Float(perShot.count)
        let kinds = perShot.map(\.kind.title).joined(separator: "+")
        q.notes = String(format: "희소 피팅(%@, 컷 %d개: %@). 스케일은 1 로 고정 — 단안 사진은 절대 크기를 알 수 없다. 랜드마크 변위 최대 %.1f mm · 재투영 평균 %.2f px",
                         perShot.first?.intrinsicsEstimated == true ? "intrinsics 가정 FOV" : "intrinsics 센서값",
                         perShot.count, kinds, maxDisp * 1000, avgReproj)
        return Identity(templateID: m.id, templateVersion: m.version, positions: positions, scale: 1,
                        eyeCenterL: eyeL, eyeCenterR: eyeR, eyeRadius: m.eyeRadius, patchDeltas: [:], quality: q)
    }

    // MARK: 작은 3×3 선형대수 (의존성 없이)

    static let identity3 = simd_float3x3(columns: (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)))

    /// 외적 a·bᵀ (3×3).
    static func outer(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> simd_float3x3 {
        simd_float3x3(columns: (a * b.x, a * b.y, a * b.z))
    }

    static func safeNormalize(_ v: SIMD3<Float>) -> SIMD3<Float>? {
        let len = simd_length(v)
        guard len > 1e-9 else { return nil }
        return v / len
    }
}
