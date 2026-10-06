//
//  CaptureTier.swift
//  CoursonaCore
//
//  입력 등급 A/B/C (TechPRD §3·§5). 원래 `CoursonaCapture`에 있었으나(T-005), C8 UI 2단계에서
//  `CoursonaManifest`(패키지 저장)가 등급을 알아야 해서 `CoursonaCore`로 옮겼다 — 반대 방향 의존(Core→Capture)은
//  만들 수 없어서다. 판정 로직(`TierClassifier`)은 여전히 `CoursonaCapture`에 남는다, 이 타입만 재노출한다.
//

import Foundation

public enum CaptureTier: String, Sendable, Equatable, CaseIterable, Codable {
    /// Face ID 카메라(TrueDepth) — 얼굴 형태·깊이를 직접 측정한다.
    case a
    /// 일반 전면 카메라(Mac 전부·Face ID 없는 iPhone·iPad) — 얼굴 치수는 추정.
    case b
    /// 사진 1장 — 사용자가 직접 선택했을 때만. 자동 판정 결과로는 나오지 않는다.
    case c
}
