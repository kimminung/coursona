//
//  PhotoSuitability.swift
//  CoursonaCapture
//
//  C 등급(T-303): 사진 1장(`PhotosPicker`/파일 가져오기) 적합성 검사 — 정면·눈 뜸·입 다묾·밝기·얼굴 크기.
//  B 등급 게이트(`PhotoCaptureGate`)와 **같은 임계값**을 재사용한다 — 한 장짜리 사진도 결국 B 등급 정면 컷과
//  같은 기준으로 괜찮아야 피팅이 통한다(새 상수를 만들지 않는다). 평가 자체는 순수 로직(Vision 비의존)이라
//  합성 값으로 단위 테스트가 가능하고, Vision 호출은 `check(_:)` 래퍼에만 있다.
//

import Foundation
import CoreGraphics

public struct PhotoSuitabilityReport: Sendable, Equatable {
    public var isSuitable: Bool
    /// 실패 이유(한글, 사용자에게 바로 보여줄 문장). 비었으면 적합.
    public var reasons: [String]
}

public enum PhotoSuitability {
    /// 순수 평가 — Vision 분석 결과를 이미 가지고 있을 때(혹은 테스트에서 합성 값으로) 쓴다.
    /// `captureQualityScore`·`personCoverage`(T-302) 는 기본값 1(측정 안 함 = 막을 이유 없음) — 기존 호출부를 안 건드린다.
    public static func evaluate(yaw: Float, pitch: Float, eyeAspectRatio: Float, mouthOpenRatio: Float,
                                brightness: Float, faceWidthRatio: Float, captureQualityScore: Float = 1, personCoverage: Float = 1,
                                gate: PhotoCaptureGate = PhotoCaptureGate()) -> PhotoSuitabilityReport {
        var reasons: [String] = []
        if abs(yaw) > gate.yawTolerance { reasons.append("정면을 보고 다시 찍어 주세요") }
        if abs(pitch) > gate.pitchTolerance { reasons.append("고개를 너무 들거나 숙이지 마세요") }
        if eyeAspectRatio < gate.eyesClosedMaxAspect { reasons.append("눈을 뜨고 찍어 주세요") }
        if mouthOpenRatio > gate.mouthOpenMinRatio { reasons.append("입을 다물어 주세요") }
        if !gate.brightnessRange.contains(brightness) {
            reasons.append(brightness < gate.brightnessRange.lowerBound ? "더 밝은 곳에서 찍어 주세요" : "너무 밝습니다 — 역광을 피하세요")
        }
        if faceWidthRatio < gate.minFaceWidthRatio { reasons.append("얼굴이 너무 작습니다 — 더 가까이서 찍어 주세요") }
        if captureQualityScore < gate.minCaptureQuality { reasons.append("조금 더 선명하게, 정면에서 찍어 주세요") }
        if personCoverage < gate.minPersonCoverage { reasons.append("얼굴이 배경과 잘 구분되지 않습니다") }
        return PhotoSuitabilityReport(isSuitable: reasons.isEmpty, reasons: reasons)
    }

#if os(macOS) || os(iOS)
    /// 사진 파일(또는 `PhotosPicker` 로 고른 이미지) 한 장 → 적합성. 얼굴을 못 찾으면 nil.
    public static func check(_ image: CGImage, gate: PhotoCaptureGate = PhotoCaptureGate()) async throws -> PhotoSuitabilityReport? {
        guard let a = try await PhotoCaptureSession.analyze(image) else { return nil }
        let brightness = PhotoCaptureSession.brightness(image, in: a.box)
        let faceWidthRatio = Float(a.box.width) / Float(max(1, image.width))
        return evaluate(yaw: a.pose.x, pitch: a.pose.y, eyeAspectRatio: a.eyeAspectRatio, mouthOpenRatio: a.mouthOpenRatio,
                        brightness: brightness, faceWidthRatio: faceWidthRatio, captureQualityScore: a.captureQualityScore,
                        personCoverage: a.personCoverage, gate: gate)
    }
#endif
}
