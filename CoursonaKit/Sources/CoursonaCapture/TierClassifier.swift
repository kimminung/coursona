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
//  🧪 실기기(iPhone 16)에서 확인된 함정: 카메라 권한이 아직 결정되지 않은 **최초 실행**에는 `session.start()` 가
//  시스템 권한 팝업을 띄우고, ARKit 은 사용자가 응답하기 전까지 프레임을 전혀 안 준다. 사용자가 팝업에 응답하는
//  시간이 아래 2초(`depthTimeout`) 를 다 써버리면 TrueDepth 기기도 A 가 아니라 B 로 떨어진다 — 하드웨어 문제가
//  아니라 "권한 대기 시간이 깊이-대기 시간을 깎아먹는" 타이밍 문제다. 그래서 권한이 `.notDetermined` 면 먼저
//  물어보고 **응답을 기다린 다음** 깊이-대기 타이머를 시작한다(권한 대기 시간은 depthTimeout 에서 빼지 않는다).
//

import Foundation
#if os(iOS)
import AVFoundation
#endif

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
        // 권한이 아직 안 정해졌으면(최초 실행) 팝업 응답을 기다린다 — 이 대기는 depthTimeout 에 포함하지 않는다.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return .b }
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
