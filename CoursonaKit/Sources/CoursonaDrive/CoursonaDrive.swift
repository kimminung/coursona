//
//  CoursonaDrive.swift
//  CoursonaDrive
//
//  라이브 구동(거울) 모듈 — 신규(TechPRD §6.8). "Vision Pro 페르소나처럼" 을 iPhone·iPad·Mac 에서.
//  C6 에서 채운다. 지금은 모듈 경계만 선언한다(T-002).
//
//  계획된 타입(C6):
//    ARKitFaceDriver   iOS·iPadOS(Face ID) — ARKit 52 + 고개(초상 라이브 경로 재사용)
//    VisionFaceDriver  macOS 기본·iOS 폴백 — Vision 76점 → 12 셰이프 + 자세, 1€ 필터, 2초 캘리브레이션.
//                      연속 신호 합성은 async/await 와 함께 Combine 을 써도 된다(TechPRD §6.1 — 이 프로젝트는
//                      Combine 을 금지하지 않는다).
//    MicVisemeDriver   마이크 비셈 보완(HangulViseme·MicLevelMeter)
//

import Foundation
import CoursonaCore
import CoursonaRig

public enum CoursonaDrivePlaceholder {
    public static let visionShapeCount = 12
}
