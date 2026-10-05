//
//  SparseFaceGeometry.swift
//  CoursonaCore
//
//  희소 캡처(T-205: TrueDepth 없는 Mac 카메라·iPhone 폴백·사진 파일)의 결정적 기하.
//  Vision 76 랜드마크(픽셀) + 자세 각도 → 핵심점 · 가정 FOV intrinsics · 얼굴 변환 추정. 언어 모델은 쓰지 않는다(CLAUDE.md 원칙).
//
//  규약 (CaptureBundle.swift 와 동일): 이미지는 비반전(거울 아님) — 피사체의 왼쪽이 이미지 오른쪽에 보인다.
//  카메라 좌표: x 오른쪽, y 위, 카메라는 −Z 를 본다. 얼굴 좌표: +X 피사체 왼쪽, +Y 위, +Z 얼굴 앞(정면이면 카메라 쪽).
//  yaw + = 피사체가 자기 왼쪽으로 고개를 돌림(코끝이 이미지 오른쪽으로 이동). pitch + = 위. roll + = 이미지에서 반시계.
//

import Foundation
import simd
import CoreGraphics

public enum SparseFaceGeometry {
    /// 가정 동공 간 거리 (m). 성인 평균 63 mm — 깊이 추정의 척도.
    public static let assumedInterpupillary: Float = 0.063
    /// 얼굴 좌표계 원점(머리 중심)에서 본 두 눈 중점의 위치 (m). ARKit 얼굴 앵커 기준 대략값(눈은 원점보다 3 cm 위, 5.5 cm 앞).
    public static let eyeMidpointInFace = SIMD3<Float>(0, 0.03, 0.055)
    /// Mac 내장 카메라의 가정 수평 FOV (도). `videoFieldOfView` 는 macOS 에 없다.
    public static let assumedMacHorizontalFOV: Float = 60

    /// 수평 FOV(도)·이미지 크기 → 핀홀 intrinsics (정사각 픽셀, 주점 중앙).
    public static func intrinsics(horizontalFOVDegrees fov: Float, width: Int, height: Int) -> Geometry.Intrinsics {
        let f = Float(width) / 2 / tan(fov * .pi / 360)
        return Geometry.Intrinsics(fx: f, fy: f, cx: Float(width) / 2, cy: Float(height) / 2, width: width, height: height)
    }

    /// 두 눈 윤곽 점 집합 → 핵심점. 어느 쪽이 피사체 왼쪽인지는 **이미지 x 로 결정**한다(Vision 의 left/right 명명에 기대지 않는다).
    /// - Parameters: eyeA/eyeB 눈 윤곽(픽셀), nose 코 윤곽, lipsOuter 바깥 입술, contour 얼굴 윤곽.
    public static func keyPoints(eyeA: [SIMD2<Float>], eyeB: [SIMD2<Float>], nose: [SIMD2<Float>], noseCrest: [SIMD2<Float>],
                                 lipsOuter: [SIMD2<Float>], contour: [SIMD2<Float>]) -> [LandmarkName: SIMD2<Float>] {
        var out: [LandmarkName: SIMD2<Float>] = [:]
        guard !eyeA.isEmpty, !eyeB.isEmpty else { return out }
        let ca = centroid(eyeA), cb = centroid(eyeB)
        // 피사체 왼쪽 눈 = 이미지 오른쪽(x 큰 쪽)
        let (left, right) = ca.x > cb.x ? (eyeA, eyeB) : (eyeB, eyeA)
        // 눈 꼬리: 왼눈의 바깥 = x 최대, 안쪽 = x 최소. 오른눈은 반대.
        out[.eyeLeftOuter] = left.max { $0.x < $1.x }
        out[.eyeLeftInner] = left.min { $0.x < $1.x }
        out[.eyeRightOuter] = right.min { $0.x < $1.x }
        out[.eyeRightInner] = right.max { $0.x < $1.x }
        // 코끝: 코 능선의 마지막 점(위→아래 순서) 이 있으면 그것, 없으면 코 윤곽에서 가장 아래(y 최대) 점
        if let tip = noseCrest.last { out[.noseTip] = tip }
        else if let tip = nose.max(by: { $0.y < $1.y }) { out[.noseTip] = tip }
        if !lipsOuter.isEmpty {
            out[.mouthLeft] = lipsOuter.max { $0.x < $1.x }
            out[.mouthRight] = lipsOuter.min { $0.x < $1.x }
        }
        if let chin = contour.max(by: { $0.y < $1.y }) { out[.chin] = chin }
        return out
    }

    /// 눈 중심(윤곽 평균) — 피사체 왼쪽·오른쪽.
    public static func eyeCenters(_ k: [LandmarkName: SIMD2<Float>]) -> (left: SIMD2<Float>, right: SIMD2<Float>)? {
        guard let lo = k[.eyeLeftOuter], let li = k[.eyeLeftInner], let ro = k[.eyeRightOuter], let ri = k[.eyeRightInner] else { return nil }
        return ((lo + li) / 2, (ro + ri) / 2)
    }

    /// 랜드마크만으로 정한 yaw 부호: 코끝이 두 눈 중점보다 이미지 오른쪽이면 +(피사체 왼쪽으로 돌림). 치우침이 눈 간격의 3 % 미만이면 0.
    public static func yawSign(_ k: [LandmarkName: SIMD2<Float>]) -> Float {
        guard let eyes = eyeCenters(k), let nose = k[.noseTip] else { return 0 }
        let mid = (eyes.left + eyes.right) / 2
        let spacing = max(1e-3, simd_length(eyes.left - eyes.right))
        let d = (nose.x - mid.x) / spacing
        return abs(d) < 0.03 ? 0 : (d > 0 ? 1 : -1)
    }

    /// Vision 자세(도) → 우리 규약. yaw 는 크기만 쓰고 부호는 랜드마크로 정한다(Vision 부호 규약에 기대지 않음). pitch 는 Vision 이 오른손 좌표계(x 오른쪽·y 위·z 보는 사람 쪽)라서 + 가 턱 내림 → 뒤집는다 🧪. roll 은 그대로(반시계 +).
    public static func pose(visionYaw: Float, visionPitch: Float, visionRoll: Float, keyPoints k: [LandmarkName: SIMD2<Float>]) -> SIMD3<Float> {
        let s = yawSign(k)
        let yaw = s == 0 ? min(abs(visionYaw), 3) * (visionYaw >= 0 ? 1 : -1) : s * abs(visionYaw)
        return SIMD3(yaw, -visionPitch, visionRoll)
    }

    /// 얼굴 → 카메라 변환 추정. 깊이는 눈 간격(픽셀)과 가정 동공 거리로: z = f · IPD · cos(yaw) / d_px.
    /// 회전 R = Ry(yaw) · Rx(−pitch) · Rz(roll). 원점 = 눈 중점 − R·eyeMidpointInFace.
    public static func estimateFaceTransform(eyeLeft: SIMD2<Float>, eyeRight: SIMD2<Float>, poseDegrees p: SIMD3<Float>, intrinsics K: Geometry.Intrinsics,
                                             interpupillary ipd: Float = assumedInterpupillary) -> simd_float4x4 {
        let rad = Float.pi / 180
        let qy = simd_quatf(angle: p.x * rad, axis: [0, 1, 0])
        let qx = simd_quatf(angle: -p.y * rad, axis: [1, 0, 0])
        let qz = simd_quatf(angle: p.z * rad, axis: [0, 0, 1])
        let R = qy * qx * qz
        let dpx = max(1, simd_length(eyeLeft - eyeRight))
        let z = K.fx * ipd * max(0.2, cos(p.x * rad)) / dpx
        let mid = (eyeLeft + eyeRight) / 2
        let eyeMidCam = K.unproject(mid, depth: z)
        let origin = eyeMidCam - R.act(eyeMidpointInFace)
        var m = simd_float4x4(R)
        m.columns.3 = SIMD4(origin, 1)
        return m
    }

    /// 변환에서 yaw/pitch(도) 를 다시 읽는다 (ARKit 경로와 같은 식 — `Geometry.faceYawPitch`).
    public static func yawPitch(of faceInCamera: simd_float4x4) -> (yaw: Float, pitch: Float) {
        Geometry.faceYawPitch(faceInCamera: faceInCamera)
    }

    static func centroid(_ p: [SIMD2<Float>]) -> SIMD2<Float> { p.reduce(.zero, +) / Float(max(1, p.count)) }
}
