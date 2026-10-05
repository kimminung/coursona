//
//  DepthRegistration.swift
//  CoursonaCore (M4 에서 CoursonaFit → Core 로: 텍스처 모듈도 쓴다)
//
//  TrueDepth 깊이 ↔ ARKit 얼굴 메시 정합 (M3 에서 발견한 편차).
//  실기기 번들(iPhone 16)에서 **메시 정점을 카메라로 투영한 픽셀의 깊이가 메시 z 보다 일관되게 약 25 mm 가깝다**
//  (4컷 중앙값 −23 … −31 mm, 정면 컷의 가로 어긋남은 1 px 미만). 어느 쪽이 절대 치수로 맞는지는 이 번들만으로 판정할 수 없다 —
//  초상은 ARKit 메시를 얼굴의 진실로 삼으므로(패치 치환) **깊이를 메시에 맞춘다**: 컷마다 카메라를 향한 정점(cos > 0.6, 얼굴 중앙)에서
//  (깊이 − 메시 z) 의 중앙값을 재어 그 컷의 깊이 전체에서 뺀다. 가장자리(비스듬한 면·머리카락·배경) 는 다른 면을 찍으므로 넣지 않는다.
//  스케일(기울기)은 쓰지 않는다 — 전체 정점 회귀의 기울기 0.6–0.87 은 가장자리 오염으로 보이며 중앙 영역만으로는 상수로 충분했다.
//  🧪 바른 해법은 캡처 쪽에서 `AVDepthData.cameraCalibrationData`(깊이 카메라 intrinsics·extrinsics) 를 번들에 저장하는 것(M2 후속).
//

import Foundation
import simd


public enum DepthRegistration {
    public struct Result: Sendable, Equatable {
        /// 깊이 − 메시 z 의 중앙값 (m). 보정 = 깊이 − offset
        public var offset: Float
        public var samples: Int
        /// 보정 후 |깊이 − 메시 z| 의 중앙값 (m) — 남는 불일치
        public var residualMedian: Float
    }

    /// 한 컷의 깊이 오프셋. 깊이·메시가 없거나 표본이 30개 미만이면 nil.
    public static func estimate(shot: CaptureShot, template t: BustTemplate, minCos: Float = 0.6) -> Result? {
        guard let depth = shot.depth, let Kd = shot.depthIntrinsics else { return nil }
        let raw = shot.meta.faceVertexArray
        let pc = t.patchCount
        guard raw.count == pc else { return nil }
        // 패치 삼각형만으로 메시 법선 (얼굴 좌표)
        var tris: [UInt32] = []
        tris.reserveCapacity(t.indices.count)
        var k = 0
        while k + 2 < t.indices.count {
            let a = t.indices[k], b = t.indices[k + 1], c = t.indices[k + 2]
            if a < pc, b < pc, c < pc { tris += [a, b, c] }
            k += 3
        }
        let normals = Geometry.vertexNormals(positions: raw, indices: tris)
        let faceInCam = shot.cameraTransform.inverse * shot.faceTransform
        var diffs: [Float] = []
        for i in 0..<pc {
            let pcam = Geometry.transformPoint(faceInCam, raw[i])
            let ncam = Geometry.transformDirection(faceInCam, normals[i])
            // 카메라(원점)를 향한 면만
            guard simd_dot(simd_normalize(ncam), simd_normalize(-pcam)) > minCos else { continue }
            guard let px = Kd.project(pcam), let dz = depth.sample(px) else { continue }
            diffs.append(dz - (-pcam.z))
        }
        guard diffs.count >= 30 else { return nil }
        diffs.sort()
        let med = diffs[diffs.count / 2]
        var res = diffs.map { abs($0 - med) }
        res.sort()
        return Result(offset: med, samples: diffs.count, residualMedian: res[res.count / 2])
    }

    /// 보정한 깊이 맵 (깊이 − offset, 유효 픽셀만).
    public static func corrected(_ depth: DepthMap, offset: Float) -> DepthMap {
        guard abs(offset) > 1e-6 else { return depth }
        var d = depth
        for i in d.values.indices where depth.isValid(d.values[i]) { d.values[i] -= offset }
        return d
    }
}
