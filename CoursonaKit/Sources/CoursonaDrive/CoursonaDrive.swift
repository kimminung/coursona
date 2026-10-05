//
//  CoursonaDrive.swift
//  CoursonaDrive
//
//  라이브 구동(거울) 모듈 — TechPRD §6.8. "Vision Pro 페르소나처럼" 을 iPhone·iPad·Mac 에서.
//
//  타입(C6):
//    ARKitFaceDriver       iOS·iPadOS(Face ID, T-601) — `ARKitFaceDriver.swift`, ARKit 52 + 머리 자세(🧪 미검증).
//    VisionFaceDriver      macOS 기본·iOS 폴백(T-602) — `VisionFaceDriver.swift`, `PhotoCaptureSession` 재사용 +
//                          `VisionFaceSignals`(순수 로직, 단위 테스트 가능) + 1€ 필터 + 2초 중립 캘리브레이션.
//    MicVisemeDriver       마이크 보완(T-603) — `MicVisemeDriver.swift`, `MicLevelMeter`·`HangulViseme` 래퍼.
//    FaceDriverCoordinator 우선순위 합성(ARKit > Vision > 마이크만) — `FaceDriverCoordinator.swift`.
//  연속 신호 합성은 async/await 와 함께 Combine 을 써도 된다(TechPRD §6.1 — 이 프로젝트는 Combine 을 금지하지 않는다).
//  `FaceRigSystem`/`ExpressionMixer`(클립⊕라이브⊕비셈⊕깜빡임 합성, T-604)는 `CoursonaRig/FaceRig.swift` 에 이미
//  포팅돼 있다 — 이 모듈의 드라이버들은 그 입력(`FaceRigComponent.externalWeights`/`audioLevel`/`visemeQueue`)만 채운다.
//

import Foundation
import CoursonaCore
import CoursonaRig
