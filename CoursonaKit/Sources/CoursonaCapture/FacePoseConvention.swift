//
//  FacePoseConvention.swift
//  CoursonaCapture
//
//  캡처 가이드가 쓰는 **얼굴 자세 부호 규약** (T-203). 순수 함수라 전 플랫폼에서 테스트한다.
//
//  규약(Blender-요청.md §0 · CaptureBundle.swift):
//    yaw  + = 피사체가 **자기 왼쪽**으로 고개를 돌림 (카메라에서는 오른쪽 뺨이 보인다)
//    pitch + = 턱을 듦
//
//  실측(iPhone 16 / 전면 TrueDepth / 세로, 2026-10-04): 포트레이트 카메라 기준으로 `Geometry.faceYawPitch` 를 그대로 쓰면
//  피사체가 자기 **오른쪽**으로 돌릴 때 양수가 나온다 — 규약과 반대다. 기기 로그가 그대로 보여 줬다:
//    `촬영 left (수동) — yaw −26.6°(목표 30)` · `촬영 right (자동) — yaw −26.2°(목표 −30)`
//  → 왼쪽으로 돌렸는데 오른쪽 컷이 자동 촬영됐다. pitch 는 규약과 같다(`up (자동) … pitch 20.9°(목표 15)`).
//
//  여기서 **UI 게이트용 각도만** 뒤집는다. 번들에 저장되는 `faceTransform`·`cameraTransform` 은 원본 그대로라
//  피팅·텍스처(M3·M4)는 영향을 받지 않는다.
//

import Foundation
import simd
import CoursonaCore

public enum FacePoseConvention {
    /// 포트레이트 카메라 기준 얼굴 변환 → 가이드 UI 가 쓰는 (yaw, pitch). 부호 규약은 위 주석 참고.
    public static func guideAngles(faceInPortraitCamera m: simd_float4x4) -> (yaw: Float, pitch: Float) {
        let raw = Geometry.faceYawPitch(faceInCamera: m)
        return (-raw.yaw, raw.pitch)
    }

    /// 규약을 한 줄로 (진단 화면·문서용).
    public static let description = "yaw + = 내 왼쪽으로 고개 돌림(오른쪽 뺨이 카메라로) · pitch + = 턱 듦"
}
