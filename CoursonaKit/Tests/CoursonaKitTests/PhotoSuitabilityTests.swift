import Testing
@testable import CoursonaCapture

/// T-303: C 등급 사진 1장 적합성 평가(순수 로직, Vision 비의존 — `check(_:)` 의 Vision 래퍼는 🧪 실기기/실제 이미지 필요).
@Suite("사진 적합성 (T-303)")
struct PhotoSuitabilityTests {
    static let goodGate = PhotoCaptureGate()

    @Test("자세·눈·입·밝기·크기 전부 괜찮으면 적합, 이유 없음")
    func allGood() {
        let r = PhotoSuitability.evaluate(yaw: 2, pitch: -1, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(r.isSuitable && r.reasons.isEmpty)
    }

    @Test("고개가 옆으로 많이 돌아가면(yaw 초과) 부적합")
    func yawTooLarge() {
        let r = PhotoSuitability.evaluate(yaw: 20, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(!r.isSuitable && r.reasons.contains("정면을 보고 다시 찍어 주세요"))
    }

    @Test("턱을 너무 들거나 숙이면(pitch 초과) 부적합")
    func pitchTooLarge() {
        let r = PhotoSuitability.evaluate(yaw: 0, pitch: 15, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(!r.isSuitable && r.reasons.contains("고개를 너무 들거나 숙이지 마세요"))
    }

    @Test("눈 종횡비가 낮으면(눈 감음) 부적합")
    func eyesClosed() {
        let r = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.05, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(!r.isSuitable && r.reasons.contains("눈을 뜨고 찍어 주세요"))
    }

    @Test("입 벌림 비율이 높으면 부적합")
    func mouthOpen() {
        let r = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.4, brightness: 0.5, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(!r.isSuitable && r.reasons.contains("입을 다물어 주세요"))
    }

    @Test("너무 어둡거나 밝으면 그에 맞는 문장")
    func brightnessOutOfRange() {
        let dark = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.05, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(dark.reasons.contains("더 밝은 곳에서 찍어 주세요"))
        let bright = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.95, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(bright.reasons.contains("너무 밝습니다 — 역광을 피하세요"))
    }

    @Test("얼굴이 이미지에서 너무 작으면 부적합")
    func faceTooSmall() {
        let r = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.05, gate: Self.goodGate)
        #expect(!r.isSuitable && r.reasons.contains("얼굴이 너무 작습니다 — 더 가까이서 찍어 주세요"))
    }

    @Test("여러 조건이 동시에 걸리면 이유가 여러 개 쌓인다")
    func multipleReasons() {
        let r = PhotoSuitability.evaluate(yaw: 25, pitch: 0, eyeAspectRatio: 0.05, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(r.reasons.count == 2)
    }

    @Test("캡처 품질 점수가 낮으면 부적합(T-302)")
    func lowCaptureQuality() {
        let r = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3,
                                          captureQualityScore: 0.2, gate: Self.goodGate)
        #expect(!r.isSuitable && r.reasons.contains("조금 더 선명하게, 정면에서 찍어 주세요"))
    }

    @Test("인물 매트 비율이 낮으면 부적합(T-302)")
    func lowPersonCoverage() {
        let r = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3,
                                          personCoverage: 0.3, gate: Self.goodGate)
        #expect(!r.isSuitable && r.reasons.contains("얼굴이 배경과 잘 구분되지 않습니다"))
    }

    @Test("T-302 값을 안 주면 기본값 1 이라 기존 호출부처럼 막지 않는다")
    func defaultsDoNotBlock() {
        let r = PhotoSuitability.evaluate(yaw: 0, pitch: 0, eyeAspectRatio: 0.3, mouthOpenRatio: 0.05, brightness: 0.5, faceWidthRatio: 0.3, gate: Self.goodGate)
        #expect(r.isSuitable)
    }
}
