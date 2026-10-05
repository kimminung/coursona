import Testing
import Foundation
import simd
@testable import CoursonaCore

/// 가로 센서 → 세로 저장 방향 회전 (T-203 실기기 버그 회귀).
/// intrinsics 와 카메라 변환이 **같은 방향**으로 돌아야 재투영이 맞는다. 어긋나면 투영점이 주점 기준 점대칭으로 뒤집힌다.
@Suite("포트레이트 회전")
struct PortraitRotationTests {
    /// iPhone 전면 카메라와 비슷한 가로 intrinsics (1440×1080, 주점이 중앙에서 살짝 벗어남)
    static let land = Geometry.Intrinsics(fx: 1200, fy: 1205, cx: 715, cy: 545, width: 1440, height: 1080)

    @Test("회전된 intrinsics 의 크기·초점·주점")
    func rotatedIntrinsics() {
        let p = Geometry.portraitRotated(Self.land)
        #expect(p.width == 1080 && p.height == 1440)
        #expect(p.fx == 1205 && p.fy == 1200)
        #expect(p.cx == 1080 - 545 && p.cy == 715)
        // 두 번 돌리면 180° — 크기는 원래대로, 주점은 반대편
        let twice = Geometry.portraitRotated(p)
        #expect(twice.width == 1440 && twice.height == 1080)
        #expect(abs(twice.cx - (1440 - 715)) < 1e-4 && abs(twice.cy - (1080 - 545)) < 1e-4)
    }

    @Test("카메라 회전 + intrinsics 회전 = 픽셀 (x', y') = (H − y, x)")
    func reprojectionMatchesPixelMapping() {
        let K = Self.land
        let P = Geometry.portraitRotated(K)
        let R = Geometry.portraitCameraRotation
        // 카메라 앞(−Z)의 여러 점: 얼굴 범위 정도
        var worst: Float = 0
        for i in 0..<64 {
            let t = Float(i)
            let p = SIMD3<Float>(sin(t * 0.7) * 0.09, cos(t * 1.3) * 0.11 + 0.02, -(0.30 + Float(i % 7) * 0.03))
            guard let land = K.project(p) else { Issue.record("가로 투영 실패"); continue }
            // 같은 점을 회전된 카메라 좌표로 옮겨 회전된 intrinsics 로 투영
            let pRot = Geometry.transformPoint(R.inverse, p)
            guard let port = P.project(pRot) else { Issue.record("세로 투영 실패"); continue }
            let expected = SIMD2<Float>(Float(K.height) - land.y, land.x)
            worst = max(worst, simd_length(port - expected))
        }
        #expect(worst < 1e-2, "재투영 오차 \(worst) px — intrinsics 와 카메라 회전 방향이 어긋났다")
    }

    @Test("반대 방향으로 돌리면 주점 기준 점대칭으로 어긋난다 (옛 버그의 모양)")
    func wrongDirectionIsPointSymmetric() {
        let K = Self.land
        let P = Geometry.portraitRotated(K)
        let wrong = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 0, 1]))
        let p = SIMD3<Float>(0.04, 0.06, -0.35)
        let good = P.project(Geometry.transformPoint(Geometry.portraitCameraRotation.inverse, p))!
        let bad = P.project(Geometry.transformPoint(wrong.inverse, p))!
        let mirrored = SIMD2<Float>(2 * P.cx - good.x, 2 * P.cy - good.y)
        #expect(simd_length(bad - mirrored) < 1e-2)
    }

    @Test("세로 intrinsics 로 역투영하면 회전된 카메라 좌표가 돌아온다")
    func unprojectRoundTrip() {
        let P = Geometry.portraitRotated(Self.land)
        let R = Geometry.portraitCameraRotation
        let p = SIMD3<Float>(-0.03, 0.05, -0.42)
        let pRot = Geometry.transformPoint(R.inverse, p)
        let px = P.project(pRot)!
        let back = P.unproject(px, depth: -pRot.z)
        #expect(simd_length(back - pRot) < 1e-4)
    }
}
