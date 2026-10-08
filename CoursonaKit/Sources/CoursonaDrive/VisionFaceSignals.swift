//
//  VisionFaceSignals.swift
//  CoursonaDrive
//
//  C6(T-602) 순수 로직: `PhotoCaptureSession.status`(Vision 기하값, B 등급 캡처와 같은 파이프라인)를
//  중립 캘리브레이션 기준값과 비교해 ArkitWeights 일부(12 특징) + yaw/pitch/roll 로 바꾼다.
//  카메라·Vision 의존이 전혀 없는 순수 함수라 합성 `PhotoFrameStatus` 값으로 단위 테스트가 가능하다
//  (T-302 `PersonCoverage.swift` 와 같은 "순수 로직 분리" 패턴).
//
//  🧪 모든 임계값(완전히 감았을 때 EAR 비율, 최대로 벌렸을 때 jawOpen 분모 등)과 시선 부호는 경험적 추정이다 —
//  실기기로 조정이 필요하다(T-605).
//

import Foundation
import CoursonaCore
import CoursonaCapture

public enum VisionFaceSignals {
    /// 중립(무표정) 자세에서의 기준 기하값. 2초 캘리브레이션으로 채운다.
    public struct Baseline: Sendable, Equatable {
        public var earLeft: Float = 0.28
        public var earRight: Float = 0.28
        public var mouthWidthRatio: Float = 0.25
        public var innerLipsAspect: Float = 0.15
        /// 입을 다문 중립의 입 벌림 비율 — 0 이 아닐 수 있다(입술 두께·수염). 빼지 않으면 다문 입이 조금 벌어져 보였다(Mac 실측 2026-10-08).
        public var mouthOpenRatio: Float = 0
        public var browRaiseLeft: Float = 0.12
        public var browRaiseRight: Float = 0.12
        public init() {}
    }

    public struct Derived: Sendable {
        public var weights: ArkitWeights
        public var yaw: Float
        public var pitch: Float
        public var roll: Float
    }

    /// 이 함수가 채울 수 있는 ArkitShape 전부 — 드라이버가 채널별 1€ 필터를 이 목록으로 준비한다.
    public static let drivenShapes: [ArkitShape] = [
        .eyeBlinkLeft, .eyeBlinkRight, .jawOpen, .mouthSmileLeft, .mouthSmileRight, .mouthPucker, .mouthFunnel,
        .browInnerUp, .browDownLeft, .browDownRight,
        .eyeLookInLeft, .eyeLookOutLeft, .eyeLookInRight, .eyeLookOutRight,
        .eyeLookUpLeft, .eyeLookDownLeft, .eyeLookUpRight, .eyeLookDownRight,
    ]

    public static func derive(status: PhotoFrameStatus, baseline: Baseline) -> Derived {
        var w = ArkitWeights()

        func blink(_ ear: Float, base: Float) -> Float {
            guard base > 0.02 else { return 0 }
            let closedAt = base * 0.35 // 경험값: 중립의 35% 이하면 거의 다 감았다고 본다
            let t = (base - ear) / max(0.001, base - closedAt)
            return min(1, max(0, t))
        }
        w[.eyeBlinkLeft] = blink(status.eyeAspectRatioLeft, base: baseline.earLeft)
        w[.eyeBlinkRight] = blink(status.eyeAspectRatioRight, base: baseline.earRight)

        // 입 벌림: 기존 B 등급 게이트가 쓰는 것과 같은 정의(안쪽 입술 높이/바깥 입술 폭). 중립값을 빼고 0.6 을 "최대로 벌림" 기준으로 둔다.
        w[.jawOpen] = min(1, max(0, (status.mouthOpenRatio - baseline.mouthOpenRatio) / 0.6))

        // 웃음: 입 폭이 중립보다 넓어지면(비대칭은 2D 평면상 구분이 어려워 좌우 동일하게 배분)
        let widen = (status.mouthWidthRatio - baseline.mouthWidthRatio) / max(0.02, baseline.mouthWidthRatio)
        let smile = min(1, max(0, widen))
        w[.mouthSmileLeft] = smile
        w[.mouthSmileRight] = smile

        // 오므림(입 폭이 좁아짐) · 펀넬(안쪽 입술이 더 둥글어짐, 즉 높이/폭 비가 커짐)
        let narrow = (baseline.mouthWidthRatio - status.mouthWidthRatio) / max(0.02, baseline.mouthWidthRatio)
        w[.mouthPucker] = min(1, max(0, narrow))
        let roundUp = (status.innerLipsAspect - baseline.innerLipsAspect) / max(0.02, baseline.innerLipsAspect)
        w[.mouthFunnel] = min(1, max(0, roundUp))

        // 눈썹: 중립 대비 올라감/내려감(좌우 평균해 browInnerUp, 좌우 따로 browDown)
        func raiseAmount(_ raise: Float, base: Float) -> Float { (raise - base) / max(0.01, base) }
        let upL = max(0, raiseAmount(status.browRaiseLeft, base: baseline.browRaiseLeft))
        let upR = max(0, raiseAmount(status.browRaiseRight, base: baseline.browRaiseRight))
        w[.browInnerUp] = min(1, (upL + upR) / 2)
        w[.browDownLeft] = min(1, max(0, -raiseAmount(status.browRaiseLeft, base: baseline.browRaiseLeft)))
        w[.browDownRight] = min(1, max(0, -raiseAmount(status.browRaiseRight, base: baseline.browRaiseRight)))

        // 시선: `FaceRigSystem` 의 합성 시선과 같은 모양(gx/gy 부호 하나로 반대쪽 쌍을 채움).
        // gazeY 는 이미지 좌표(아래로 증가) 기준 — 양수면 동공이 눈 중심보다 아래(시선 아래) 🧪 실기기 미확인.
        let gx = status.gazeX, gy = status.gazeY
        if gx > 0 { w[.eyeLookOutLeft] = min(1, gx); w[.eyeLookInRight] = min(1, gx) }
        else { w[.eyeLookInLeft] = min(1, -gx); w[.eyeLookOutRight] = min(1, -gx) }
        if gy > 0 { w[.eyeLookDownLeft] = min(1, gy); w[.eyeLookDownRight] = min(1, gy) }
        else { w[.eyeLookUpLeft] = min(1, -gy); w[.eyeLookUpRight] = min(1, -gy) }

        return Derived(weights: w, yaw: status.yaw, pitch: status.pitch, roll: status.roll)
    }

    /// 여러 프레임(캘리브레이션 구간)의 평균으로 기준값을 만든다. 표본이 없으면 기본값.
    public static func averageBaseline(_ samples: [PhotoFrameStatus]) -> Baseline {
        guard !samples.isEmpty else { return Baseline() }
        let n = Float(samples.count)
        var b = Baseline()
        b.earLeft = samples.reduce(0) { $0 + $1.eyeAspectRatioLeft } / n
        b.earRight = samples.reduce(0) { $0 + $1.eyeAspectRatioRight } / n
        b.mouthWidthRatio = samples.reduce(0) { $0 + $1.mouthWidthRatio } / n
        b.innerLipsAspect = samples.reduce(0) { $0 + $1.innerLipsAspect } / n
        b.mouthOpenRatio = samples.reduce(0) { $0 + $1.mouthOpenRatio } / n
        b.browRaiseLeft = samples.reduce(0) { $0 + $1.browRaiseLeft } / n
        b.browRaiseRight = samples.reduce(0) { $0 + $1.browRaiseRight } / n
        return b
    }
}
