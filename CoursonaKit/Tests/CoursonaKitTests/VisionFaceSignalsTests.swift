import Testing
@testable import CoursonaCore
@testable import CoursonaCapture
@testable import CoursonaDrive

/// C6(T-602) 순수 로직 단위 테스트 — 카메라·Vision 의존 없이 합성 `PhotoFrameStatus` 로 검증.
@Suite("Vision 얼굴 신호 (C6, T-602)")
struct VisionFaceSignalsTests {
    static let baseline = VisionFaceSignals.Baseline()

    static func neutralStatus() -> PhotoFrameStatus {
        var s = PhotoFrameStatus()
        s.isTracked = true
        s.eyeAspectRatioLeft = baseline.earLeft
        s.eyeAspectRatioRight = baseline.earRight
        s.mouthWidthRatio = baseline.mouthWidthRatio
        s.innerLipsAspect = baseline.innerLipsAspect
        s.browRaiseLeft = baseline.browRaiseLeft
        s.browRaiseRight = baseline.browRaiseRight
        s.mouthOpenRatio = 0
        s.gazeX = 0; s.gazeY = 0
        s.yaw = 0; s.pitch = 0; s.roll = 0
        return s
    }

    @Test("중립 상태는 모든 특징이 거의 0")
    func neutralGivesZero() {
        let d = VisionFaceSignals.derive(status: Self.neutralStatus(), baseline: Self.baseline)
        for shape in VisionFaceSignals.drivenShapes { #expect(d.weights[shape] < 0.05, "\(shape) 가 중립인데 \(d.weights[shape])") }
    }

    @Test("눈 종횡비가 기준의 35% 이하로 떨어지면 eyeBlink 가 거의 1")
    func lowEARGivesBlink() {
        var s = Self.neutralStatus()
        s.eyeAspectRatioLeft = Self.baseline.earLeft * 0.3
        let d = VisionFaceSignals.derive(status: s, baseline: Self.baseline)
        #expect(d.weights[.eyeBlinkLeft] > 0.95)
        #expect(d.weights[.eyeBlinkRight] < 0.05)
    }

    @Test("입 벌림 비율이 0.6 이면 jawOpen 이 1에 가깝다")
    func mouthOpenGivesJawOpen() {
        var s = Self.neutralStatus()
        s.mouthOpenRatio = 0.6
        let d = VisionFaceSignals.derive(status: s, baseline: Self.baseline)
        #expect(d.weights[.jawOpen] > 0.95)
    }

    @Test("입 폭이 기준보다 넓어지면 웃음, 좁아지면 오므림")
    func mouthWidthGivesSmileOrPucker() {
        var wide = Self.neutralStatus(); wide.mouthWidthRatio = Self.baseline.mouthWidthRatio * 1.3
        let dWide = VisionFaceSignals.derive(status: wide, baseline: Self.baseline)
        #expect(dWide.weights[.mouthSmileLeft] > 0.1)
        #expect(dWide.weights[.mouthSmileRight] > 0.1)
        #expect(dWide.weights[.mouthPucker] == 0)

        var narrow = Self.neutralStatus(); narrow.mouthWidthRatio = Self.baseline.mouthWidthRatio * 0.7
        let dNarrow = VisionFaceSignals.derive(status: narrow, baseline: Self.baseline)
        #expect(dNarrow.weights[.mouthPucker] > 0.1)
        #expect(dNarrow.weights[.mouthSmileLeft] == 0)
    }

    @Test("안쪽 입술이 더 둥글어지면(높이/폭 비 상승) funnel 이 커진다")
    func roundInnerLipsGivesFunnel() {
        var s = Self.neutralStatus(); s.innerLipsAspect = Self.baseline.innerLipsAspect * 2
        let d = VisionFaceSignals.derive(status: s, baseline: Self.baseline)
        #expect(d.weights[.mouthFunnel] > 0.1)
    }

    @Test("눈썹이 기준보다 올라가면 browInnerUp, 내려가면 browDown")
    func browRaiseGivesUpOrDown() {
        var up = Self.neutralStatus(); up.browRaiseLeft = Self.baseline.browRaiseLeft * 2; up.browRaiseRight = Self.baseline.browRaiseRight * 2
        let dUp = VisionFaceSignals.derive(status: up, baseline: Self.baseline)
        #expect(dUp.weights[.browInnerUp] > 0.1)
        #expect(dUp.weights[.browDownLeft] == 0)

        var down = Self.neutralStatus(); down.browRaiseLeft = Self.baseline.browRaiseLeft * 0.3
        let dDown = VisionFaceSignals.derive(status: down, baseline: Self.baseline)
        #expect(dDown.weights[.browDownLeft] > 0.1)
        #expect(dDown.weights[.browInnerUp] == 0)
    }

    @Test("gazeX·gazeY 부호에 따라 반대쪽이 아니라 짝이 맞는 eyeLook 쌍이 선다")
    func gazeSelectsCorrectPair() {
        var right = Self.neutralStatus(); right.gazeX = 0.5
        let dRight = VisionFaceSignals.derive(status: right, baseline: Self.baseline)
        #expect(dRight.weights[.eyeLookOutLeft] > 0)
        #expect(dRight.weights[.eyeLookInRight] > 0)
        #expect(dRight.weights[.eyeLookInLeft] == 0)
        #expect(dRight.weights[.eyeLookOutRight] == 0)

        var down = Self.neutralStatus(); down.gazeY = 0.5
        let dDown = VisionFaceSignals.derive(status: down, baseline: Self.baseline)
        #expect(dDown.weights[.eyeLookDownLeft] > 0)
        #expect(dDown.weights[.eyeLookDownRight] > 0)
        #expect(dDown.weights[.eyeLookUpLeft] == 0)
    }

    @Test("averageBaseline 은 표본들의 평균, 표본이 없으면 기본값")
    func averageBaselineComputesMean() {
        var a = PhotoFrameStatus(); a.eyeAspectRatioLeft = 0.2
        var b = PhotoFrameStatus(); b.eyeAspectRatioLeft = 0.4
        let avg = VisionFaceSignals.averageBaseline([a, b])
        #expect(abs(avg.earLeft - 0.3) < 0.0001)
        let empty = VisionFaceSignals.averageBaseline([])
        #expect(empty == VisionFaceSignals.Baseline())
    }
}
