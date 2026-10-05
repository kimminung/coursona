import Testing
import Foundation
import simd
@testable import CoursonaCore

/// T-306: 기기 방향 기록(순수 모델 — 매핑 함수 자체는 iOS 전용이라 `FaceCaptureSession`(🧪 실기기) 쪽에서만 쓰인다).
@Suite("캡처 방향 기록 (T-306)")
struct CaptureOrientationTests {
    static func makeMeta(orientation: CaptureOrientation?) -> CaptureShotMeta {
        let K = Geometry.Intrinsics(fx: 1000, fy: 1000, cx: 320, cy: 240, width: 640, height: 480)
        return CaptureShotMeta(kind: .front, imageFile: "s.jpg", depthFile: nil, imageWidth: 640, imageHeight: 480, depthWidth: nil, depthHeight: nil,
                               intrinsics: K, cameraTransform: matrix_identity_float4x4, faceTransform: matrix_identity_float4x4,
                               faceVertices: [], blendShapes: ArkitWeights(), light: LightEstimate(), averagedFrames: 1, timestamp: 0,
                               orientation: orientation)
    }

    @Test("landscapeLeft 로 저장하면 그대로 왕복한다")
    func roundTrip() throws {
        let meta = Self.makeMeta(orientation: .landscapeLeft)
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(CaptureShotMeta.self, from: data)
        #expect(back.orientation == .landscapeLeft)
    }

    @Test("orientation 필드 자체가 없는 옛 meta.json 도 그대로 읽힌다(nil)")
    func oldArchiveWithoutField() throws {
        // orientation 을 아예 안 주는 옛 호출부와 같은 모양 — 기본값 nil.
        let meta = Self.makeMeta(orientation: nil)
        #expect(meta.orientation == nil)
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(CaptureShotMeta.self, from: data)
        #expect(back.orientation == nil)
    }

    @Test("CaptureOrientation 7종 전부 왕복한다")
    func allCasesRoundTrip() throws {
        for c in [CaptureOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight, .faceUp, .faceDown, .unknown] {
            let data = try JSONEncoder().encode(c)
            #expect(try JSONDecoder().decode(CaptureOrientation.self, from: data) == c)
        }
    }
}
