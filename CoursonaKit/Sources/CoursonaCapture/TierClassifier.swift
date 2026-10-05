//
//  TierClassifier.swift
//  CoursonaCapture
//
//  입력 등급 A/B/C 판정 (TechPRD §3·§5, Tasks T-005). C(사진 1장)는 사용자가 "사진으로 만들기" 를
//  직접 선택했을 때만 들어가는 진입점이라 이 판정기의 대상이 아니다 — 여기서는 A/B 만 가른다.
//
//  규칙: `FaceCaptureSession.isSupported`(Face ID/TrueDepth) 이고, 2초 안에 `capturedDepthData`
//  가 있는 프레임을 1장이라도 받으면 A. 둘 중 하나라도 아니면 B(이 기기 카메라, 치수 추정).
//  아무 기기도 막지 않는다 — 실패하면 그냥 B 로 떨어진다.
//

import Foundation

public enum CaptureTier: String, Sendable, Equatable, CaseIterable, Codable {
    /// Face ID 카메라(TrueDepth) — 얼굴 형태·깊이를 직접 측정한다.
    case a
    /// 일반 전면 카메라(Mac 전부·Face ID 없는 iPhone/iPad) — 얼굴 치수는 추정.
    case b
    /// 사진 1장 — 사용자가 직접 선택했을 때만. 자동 판정 결과로는 나오지 않는다.
    case c
}

@MainActor
public enum TierClassifier {
    /// A/B 를 자동으로 가른다(사용자가 "Face ID 카메라로 만들기"/"이 기기 카메라로 만들기" 를 고르기 전,
    /// 또는 진입점 배지를 미리 보여줄 때 쓴다). 사진 1장(C) 경로는 이 함수를 거치지 않는다.
    public static func detectAutomaticTier(depthTimeout: TimeInterval = 2.0) async -> CaptureTier {
        #if os(iOS)
        guard FaceCaptureSession.isSupported else { return .b }
        let session = FaceCaptureSession()
        session.start()
        defer { session.stop() }
        let deadline = Date().addingTimeInterval(depthTimeout)
        while Date() < deadline {
            if session.status.hasDepth { return .a }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .b
        #else
        // macOS 에는 ARFaceTrackingConfiguration 이 없다 — 항상 B(일반 카메라).
        return .b
        #endif
    }
}
