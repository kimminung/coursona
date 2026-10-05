import Testing
import simd
@testable import CoursonaCore
@testable import CoursonaCapture

/// T-301: 저장 전 5/5 깊이 검증.
@Suite("깊이 검증 (T-301)")
struct DepthCoverageTests {
    static func shot(_ kind: ShotKind, hasDepth: Bool) -> CaptureShot {
        let K = Geometry.Intrinsics(fx: 1000, fy: 1000, cx: 320, cy: 240, width: 640, height: 480)
        let meta = CaptureShotMeta(kind: kind, imageFile: "s.jpg", depthFile: hasDepth ? "d.f32" : nil, imageWidth: 640, imageHeight: 480,
                                   depthWidth: hasDepth ? 640 : nil, depthHeight: hasDepth ? 480 : nil, intrinsics: K,
                                   cameraTransform: matrix_identity_float4x4, faceTransform: matrix_identity_float4x4,
                                   faceVertices: [], blendShapes: ArkitWeights(), light: LightEstimate(), averagedFrames: 8, timestamp: 0)
        let depth = hasDepth ? DepthMap(width: 640, height: 480, values: [Float](repeating: 0.5, count: 640 * 480)) : nil
        return CaptureShot(meta: meta, image: nil, depth: depth)
    }

    static func bundle(_ shots: [CaptureShot]) -> CaptureBundle {
        CaptureBundle(meta: CaptureBundleMeta(device: "test", sparse: false, arkitTriangleHash: nil, arkitVertexCount: 1220, shots: shots.map(\.meta)), shots: shots)
    }

    @Test("필수 5컷 전부 깊이가 있으면 통과")
    func allPresent() {
        let b = Self.bundle([.front, .left, .right, .up, .smile].map { Self.shot($0, hasDepth: true) })
        let r = DepthCoverage.check(b)
        #expect(r.isComplete && r.missing.isEmpty && r.message == nil)
    }

    @Test("한 컷만 깊이가 없으면 그 컷만 지적한다")
    func oneMissing() {
        var shots = [.front, .left, .right, .up, .smile].map { Self.shot($0, hasDepth: true) }
        shots[2] = Self.shot(.right, hasDepth: false)
        let r = DepthCoverage.check(Self.bundle(shots))
        #expect(!r.isComplete && r.missing == [.right])
        #expect(r.message?.contains("오른쪽 30°") == true)
    }

    @Test("선택 컷(눈 감기·입 벌림)은 깊이가 없어도 검사하지 않는다")
    func optionalShotsIgnored() {
        var shots = [.front, .left, .right, .up, .smile].map { Self.shot($0, hasDepth: true) }
        shots.append(Self.shot(.eyesClosed, hasDepth: false))
        shots.append(Self.shot(.mouthOpen, hasDepth: false))
        let r = DepthCoverage.check(Self.bundle(shots))
        #expect(r.isComplete)
    }

    @Test("아직 안 찍은 컷(번들에 없음)은 미지적 대상이 아니다 — 깊이 '없음' 이 아니라 '안 찍음'")
    func notYetCapturedIsNotFlagged() {
        let b = Self.bundle([.front, .left].map { Self.shot($0, hasDepth: true) })
        let r = DepthCoverage.check(b)
        #expect(r.isComplete)
    }
}
