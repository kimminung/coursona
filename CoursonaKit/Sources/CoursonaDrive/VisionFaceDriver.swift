//
//  VisionFaceDriver.swift
//  CoursonaDrive
//
//  C6(T-602) macOS 기본·iOS 폴백 라이브 구동. `PhotoCaptureSession`(B 등급 캡처와 같은 카메라·Vision 파이프라인,
//  `CoursonaCapture`)을 그대로 돌려 매 프레임 `status` 를 읽고, `VisionFaceSignals`(순수 로직)로 ArkitWeights 12
//  특징 + yaw/pitch/roll 을 만든 뒤 채널별 `OneEuroFilter` 로 떨림을 줄인다. 시작 후 `calibrationSeconds`(기본 2초)
//  동안은 무표정 기준값을 모으기만 하고(출력 없음), 그 뒤부터 중립 대비 상대값을 낸다.
//

import Foundation
import CoursonaCore
import CoursonaCapture

@MainActor
public final class VisionFaceDriver {
    public let session = PhotoCaptureSession()
    public private(set) var weights = ArkitWeights()
    public private(set) var yaw: Float = 0
    public private(set) var pitch: Float = 0
    public private(set) var roll: Float = 0
    public private(set) var isTracking = false
    public private(set) var isCalibrating = true
    public var calibrationSeconds: Double = 2.0

    private var baseline = VisionFaceSignals.Baseline()
    private var calibSamples: [PhotoFrameStatus] = []
    private var calibStart: CFAbsoluteTime?
    private var filters: [ArkitShape: OneEuroFilter] = [:]
    private var yawFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.3)
    private var pitchFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.3)
    private var rollFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.3)

    public init() {
        for shape in VisionFaceSignals.drivenShapes { filters[shape] = OneEuroFilter(minCutoff: 1.0, beta: 0.5) }
    }

    public func start() {
        isCalibrating = true
        calibSamples = []
        calibStart = nil
        for key in filters.keys { filters[key]?.reset() }
        yawFilter.reset(); pitchFilter.reset(); rollFilter.reset()
        session.start()
    }

    public func stop() {
        session.stop()
        isTracking = false
    }

    /// 디스플레이 루프(또는 타이머)에서 매 프레임 호출 — `PhotoCaptureSession` 은 카메라 프레임마다 자체적으로
    /// `status` 를 갱신하므로, 이 함수는 그 최신값을 읽어 필터링·출력만 한다.
    public func tick(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        let status = session.status
        guard status.isTracked else { isTracking = false; return }
        isTracking = true
        if calibStart == nil { calibStart = now }
        if isCalibrating {
            calibSamples.append(status)
            if now - calibStart! >= calibrationSeconds {
                baseline = VisionFaceSignals.averageBaseline(calibSamples)
                isCalibrating = false
            }
            return
        }
        let derived = VisionFaceSignals.derive(status: status, baseline: baseline)
        var filtered = ArkitWeights()
        let t = Float(now)
        for shape in VisionFaceSignals.drivenShapes {
            var f = filters[shape] ?? OneEuroFilter(minCutoff: 1.0, beta: 0.5)
            filtered[shape] = f.filter(derived.weights[shape], timestamp: t)
            filters[shape] = f
        }
        weights = filtered
        yaw = yawFilter.filter(derived.yaw, timestamp: t)
        pitch = pitchFilter.filter(derived.pitch, timestamp: t)
        roll = rollFilter.filter(derived.roll, timestamp: t)
    }
}
