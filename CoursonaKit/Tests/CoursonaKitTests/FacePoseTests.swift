import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaCapture

/// 얼굴 자세(yaw/pitch) 규약과 **실기기 측정 회귀** (T-203).
///
/// 핵심은 **두 가지 카메라 변환을 구분하는 것**이다.
/// - 런타임 `ARFrame.camera.transform` 은 **가로 기준**(x 축 = 기기 긴 축, 전면 카메라 → 홈버튼). 세로로 든 폰에서는
///   `portraitCameraRotation` 을 곱해야 좌우 회전이 yaw 로 나온다. 안 곱하면 pitch 로 새어 나간다(실측 yaw −0.8° / pitch −33.8°).
/// - 캡처 번들 `meta.cameraTransform` 은 **이미 그 회전이 적용된 값**이다. 다시 읽을 때 또 돌리면 축이 틀어진다.
///
/// 아래 행렬은 iPhone 16 번들에서 가져온 저장값(= 포트레이트 기준)이다. 머리 자세 행렬일 뿐 얼굴 형상이 아니다.
@Suite("얼굴 자세")
struct FacePoseTests {
    @Test("정면은 0°, 부호 규약 (yaw + = 피사체 왼쪽, pitch + = 턱 듦)")
    func signs() {
        let front = Geometry.faceYawPitch(faceInCamera: matrix_identity_float4x4)
        #expect(abs(front.yaw) < 1e-4 && abs(front.pitch) < 1e-4)

        let left = simd_float4x4(simd_quatf(angle: 30 * .pi / 180, axis: [0, 1, 0]))   // +Y 기준 회전 = 피사체 왼쪽
        let l = Geometry.faceYawPitch(faceInCamera: left)
        #expect(abs(l.yaw - 30) < 1e-3 && abs(l.pitch) < 1e-3)

        // 턱 듦 = 얼굴 +Z 가 위로 → X 축 기준 **음의** 회전(오른손 법칙: +X 양회전은 +Z 를 아래로 보낸다)
        let up = simd_float4x4(simd_quatf(angle: -15 * .pi / 180, axis: [1, 0, 0]))
        let u = Geometry.faceYawPitch(faceInCamera: up)
        #expect(abs(u.yaw) < 1e-3 && abs(u.pitch - 15) < 1e-3)
    }

    nonisolated static func m(_ a: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
                                SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
    }
    /// iPhone 16 실측 (2026-10-03, 세로로 들고 전면 TrueDepth). 컷별 (얼굴 변환, 카메라 변환, 기대 yaw, 기대 pitch).
    nonisolated static let device: [(String, [Float], [Float], Float, Float)] = [
        ("front", [0.99902, -0.04164, -0.01476, 0, 0.04332, 0.98898, 0.14157, 0, 0.0087, -0.14207, 0.98982, 0, -0.00772, 0.05011, -0.39343, 1],
                  [0.9999, -0.00042, -0.01418, 0, 0.00115, 0.99867, 0.05147, 0, 0.01414, -0.05148, 0.99857, 0, 0, 0, 0, 1], -0.3, -5.2),
        ("left",  [0.9213, 0.02133, -0.38827, 0, -0.01712, 0.99975, 0.01431, 0, 0.38848, -0.00654, 0.92144, 0, -0.00079, 0.06621, -0.41678, 1],
                  [0.99839, -0.05643, -0.00519, 0, 0.05654, 0.99811, 0.02411, 0, 0.00382, -0.02437, 0.9997, 0, 0, 0, 0, 1], 22.6, 2.2),
        ("up",    [0.99827, 0.05658, -0.0158, 0, -0.05775, 0.99451, -0.08723, 0, 0.01077, 0.08799, 0.99606, 0, -0.02405, 0.12461, -0.40786, 1],
                  [0.99808, -0.00342, -0.06192, 0, 0.01735, 0.97401, 0.22584, 0, 0.05954, -0.22647, 0.9722, 0, 0, 0, 0, 1], -3.1, 18.1),
    ]

    @Test("저장 메타(이미 포트레이트)는 그대로 쓰면 좌우 회전이 yaw, 턱 들기가 pitch")
    func storedMetaNeedsNoExtraRotation() {
        for (kind, face, cam, expYaw, expPitch) in Self.device {
            let faceInCam = Self.m(cam).inverse * Self.m(face)
            let (yaw, pitch) = Geometry.faceYawPitch(faceInCamera: faceInCam)
            #expect(abs(yaw - expYaw) < 0.3, "\(kind) yaw \(yaw) ≠ \(expYaw)")
            #expect(abs(pitch - expPitch) < 0.3, "\(kind) pitch \(pitch) ≠ \(expPitch)")
        }
    }

    @Test("런타임 가로 변환에는 포트레이트 회전을 적용해야 저장값과 같아진다")
    func runtimeLandscapeNeedsRotation() {
        for (kind, face, storedCam, expYaw, expPitch) in Self.device {
            // 런타임이 주는 값 = 저장값에서 회전을 빼면 된다: C_land = C_port · Rz(90)⁻¹
            let land = Self.m(storedCam) * Geometry.portraitCameraRotation.inverse
            // 세션 코드와 같은 식
            let faceInCam = (land * Geometry.portraitCameraRotation).inverse * Self.m(face)
            let (yaw, pitch) = Geometry.faceYawPitch(faceInCamera: faceInCam)
            #expect(abs(yaw - expYaw) < 0.3, "\(kind) yaw \(yaw) ≠ \(expYaw)")
            #expect(abs(pitch - expPitch) < 0.3, "\(kind) pitch \(pitch) ≠ \(expPitch)")
        }
    }

    @Test("런타임 가로 변환을 그대로 쓰면 좌우 회전이 pitch 로 새어 나간다 — 실기기 증상")
    func runtimeWithoutRotationSwapsAxes() {
        let (_, face, storedCam, expYaw, expPitch) = Self.device[1]      // left: yaw +22.6, pitch 2.2
        let land = Self.m(storedCam) * Geometry.portraitCameraRotation.inverse
        let (yaw, pitch) = Geometry.faceYawPitch(faceInCamera: land.inverse * Self.m(face))
        #expect(abs(yaw) < 5)                                            // 좌우 회전이 사라지고
        #expect(abs(abs(pitch) - abs(expYaw)) < 1)                       // pitch 로 간다
        #expect(abs(pitch - expPitch) > 15)
    }

    @Test("가로 카메라의 x 축은 기기 긴 축 — 세로로 들면 월드 아래 (실측)")
    func landscapeXAxisPointsDown() {
        let (_, _, storedCam, _, _) = Self.device[0]
        let land = Self.m(storedCam) * Geometry.portraitCameraRotation.inverse
        let x = land.columns.0
        #expect(x.y < -0.99, "기기 긴 축이 월드 아래를 향해야 한다: \(x)")
    }

    @Test("실기기 측정: 각 컷이 수정한 게이트(±9°/±8°)를 통과한다")
    func gatesPassWithLoosenedTolerances() {
        let target: [String: (Float, Float)] = ["front": (0, 0), "left": (30, 0), "up": (0, 15)]
        for (kind, face, cam, _, _) in Self.device {
            let (yaw, pitch) = Geometry.faceYawPitch(faceInCamera: Self.m(cam).inverse * Self.m(face))
            let t = target[kind]!
            #expect(abs(yaw - t.0) <= 9, "\(kind) yaw 오차 \(abs(yaw - t.0))")
            #expect(abs(pitch - t.1) <= 8, "\(kind) pitch 오차 \(abs(pitch - t.1))")
        }
        // 1차 허용치(±6/±5)였다면 front 의 pitch(−5.2°)와 left 의 yaw(22.6° vs 30°)가 걸린다 — 자동 촬영이 안 된 이유
        let (_, fFace, fCam, _, _) = Self.device[0]
        let fp = Geometry.faceYawPitch(faceInCamera: Self.m(fCam).inverse * Self.m(fFace)).pitch
        #expect(abs(fp) > 5)
        let (_, lFace, lCam, _, _) = Self.device[1]
        let ly = Geometry.faceYawPitch(faceInCamera: Self.m(lCam).inverse * Self.m(lFace)).yaw
        #expect(abs(ly - 30) > 6)
    }

    @Test("중립도는 시선 8개·깜빡임 2개를 뺀다 — 고개를 돌려도 중립 게이트를 통과할 수 있다")
    func neutralityExcludesGazeAndBlink() {
        var w = ArkitWeights()
        w[.eyeLookOutLeft] = 0.9
        w[.eyeLookInRight] = 0.85
        w[.eyeLookUpLeft] = 0.2
        w[.eyeLookUpRight] = 0.2
        w[.eyeBlinkLeft] = 0.6
        w[.eyeBlinkRight] = 0.6
        #expect(w.sum > 3)
        #expect(w.neutrality == 0)
        #expect(ArkitShape.allCases.filter(\.isGaze).count == 8)
        #expect(ArkitShape.allCases.filter(\.isBlink).count == 2)

        w[.jawOpen] = 0.5
        w[.mouthSmileLeft] = 0.4
        #expect(abs(w.neutrality - 0.9) < 1e-5)
        let top = w.topContributors(2)
        #expect(top.count == 2 && top[0].0 == .jawOpen && top[1].0 == .mouthSmileLeft)
    }

    @Test("실기기 삼각형 해시가 상수로 기록돼 있다 (T-007)")
    func triangleHashRecorded() {
        let h = try? #require(ARKitFaceTopology.referenceTriangleHash)
        #expect(h == 0x67161fe4685cdd1e)
        #expect(ARKitFaceTopology.referenceTriangleHashHex == String(format: "%016llx", ARKitFaceTopology.referenceTriangleHash ?? 0))
    }
}

/// 캡처 가이드가 쓰는 **부호 규약** (실기기 로그 회귀).
@Suite("가이드 자세 부호 규약")
struct FacePoseConventionTests {
    /// 실기기 로그(2026-10-04): 왼쪽으로 돌렸을 때 raw yaw 가 음수로 나왔고, 그 값이 오른쪽 컷(−30)을 자동 촬영시켰다.
    @Test("raw yaw 를 뒤집어 + 가 '내 왼쪽' 이 되게 한다")
    func yawSignFlipped() {
        for (_, face, cam, rawYaw, rawPitch) in FacePoseTests.device {
            let faceInCam = FacePoseTests.m(cam).inverse * FacePoseTests.m(face)
            let raw = Geometry.faceYawPitch(faceInCamera: faceInCam)
            let g = FacePoseConvention.guideAngles(faceInPortraitCamera: faceInCam)
            #expect(abs(g.yaw + raw.yaw) < 1e-4)          // yaw 만 정확히 반전
            #expect(abs(g.pitch - raw.pitch) < 1e-4)      // pitch 는 그대로
            #expect(abs(g.yaw - (-rawYaw)) < 0.3)         // 기록해 둔 실측값(반올림)과도 일치
            #expect(abs(g.pitch - rawPitch) < 0.3)
        }
    }

    @Test("실기기 상황 재현: 내 왼쪽으로 돌리면 왼쪽 컷(+30) 쪽으로 간다")
    func turningLeftMatchesLeftShot() {
        // raw yaw 가 −26.6 으로 측정된 자세(= 사용자가 자기 왼쪽으로 돌린 순간)
        let faceInCam = simd_float4x4(simd_quatf(angle: -26.6 * .pi / 180, axis: [0, 1, 0]))
        let raw = Geometry.faceYawPitch(faceInCamera: faceInCam)
        #expect(abs(raw.yaw + 26.6) < 1e-3)                       // 옛 동작: 음수 → 오른쪽 컷(−30)이 반응했다
        let g = FacePoseConvention.guideAngles(faceInPortraitCamera: faceInCam)
        #expect(abs(g.yaw - 26.6) < 1e-3)                         // 고친 뒤: 양수 → 왼쪽 컷(+30)
        #expect(abs(g.yaw - 30) <= 9)                             // 허용치 안에 들어 자동 촬영된다
        #expect(abs(g.yaw - (-30)) > 9)                           // 오른쪽 컷에는 더 이상 걸리지 않는다
    }

    @Test("오른쪽으로 돌리면 오른쪽 컷(−30)")
    func turningRightMatchesRightShot() {
        let faceInCam = simd_float4x4(simd_quatf(angle: 28 * .pi / 180, axis: [0, 1, 0]))
        let g = FacePoseConvention.guideAngles(faceInPortraitCamera: faceInCam)
        #expect(abs(g.yaw + 28) < 1e-3)
        #expect(abs(g.yaw - (-30)) <= 9)
        #expect(abs(g.yaw - 30) > 9)
    }
}
