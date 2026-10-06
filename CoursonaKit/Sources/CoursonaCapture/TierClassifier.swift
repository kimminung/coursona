//
//  TierClassifier.swift
//  CoursonaCapture
//
//  입력 등급 A/B/C 판정 (TechPRD §3·§5, Tasks T-005). C(사진 1장)는 사용자가 "사진으로 만들기" 를
//  직접 선택했을 때만 들어가는 진입점이라 이 판정기의 대상이 아니다 — 여기서는 A/B 만 가른다.
//
//  규칙: `FaceCaptureSession.isSupported`(Face ID/TrueDepth) 이고, `depthTimeout` 안에 `capturedDepthData`
//  가 있는 프레임을 1장이라도 받으면 A. 둘 중 하나라도 아니면 B(이 기기 카메라, 치수 추정).
//  아무 기기도 막지 않는다 — 실패하면 그냥 B 로 떨어진다.
//
//  🧪 실기기(iPhone 16)에서 확인된 함정 둘:
//  1) 카메라 권한이 아직 결정되지 않은 **최초 실행**에는 `session.start()` 가 시스템 권한 팝업을 띄우고, ARKit 은
//     사용자가 응답하기 전까지 프레임을 전혀 안 준다. 응답 시간이 depthTimeout 을 깎아먹지 않도록, 권한이
//     `.notDetermined` 면 먼저 물어보고 **응답을 기다린 다음** 깊이-대기 타이머를 시작한다.
//  2) **TrueDepth 깊이 프레임은 생각보다 훨씬 드물게 온다**(2026-10-06, 실제 iPhone 에 임시 진단 로그를 심어
//     직접 측정): 얼굴 추적(`isTracked`)은 0.5초 안에 바로 되는데, `capturedDepthData` 가 붙은 프레임은
//     20ms 간격 폴링 6초 동안 281번 중 **7번**만 있었다(평균 간격 ≈0.86초, 가끔 몇 초씩 비는 구간도 있음 —
//     두 차례 측정에서 첫 깊이 프레임이 각각 1.07초·3.64초만에 나타남). 옛 `depthTimeout=2.0` 는 이 변동폭
//     안에서 자주 놓칠 만큼 짧았다 — 이게 "카메라를 보고 있었는데도 TrueDepth 기기가 B 로 뜬다" 재현의 진짜
//     원인이었다(이전엔 "미리보기 없어서 카메라를 안 보고 있었다" 는 가설이었는데, 이번엔 실기기 콘솔 로그로
//     카메라가 켜져 있고 얼굴도 바로 잡혔는데도 여전히 안 됐던 걸 직접 확인해서 가설이 틀렸음을 알았다).
//     5.0 초로 올려 두 측정치(1.07s·3.64s) 모두 여유 있게 들어오게 했다 — 그래도 통계적으로 드물게 놓칠 순
//     있다(완전한 보장은 아니다, 1€ 필터처럼 "확률을 낮추는" 수준).
//

import Foundation
import CoursonaCore
#if os(iOS)
import AVFoundation
#endif

// `CaptureTier` 는 C8 2단계에서 `CoursonaCore`로 옮겼다(Formats.md/CaptureTier.swift) — 매니페스트가
// 등급을 저장하려면 Core가 이 타입을 알아야 해서다. 여기선 그대로 쓰기만 한다(재선언 없음).

@MainActor
public enum TierClassifier {
    /// A/B 를 자동으로 가른다(사용자가 "Face ID 카메라로 만들기"/"이 기기 카메라로 만들기" 를 고르기 전,
    /// 또는 진입점 배지를 미리 보여줄 때 쓴다). 사진 1장(C) 경로는 이 함수를 거치지 않는다.
    public static func detectAutomaticTier(depthTimeout: TimeInterval = 5.0) async -> CaptureTier {
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
        // 20ms 간격 폴링 — 위 머리말 2) 처럼 깊이 프레임이 드물게(평균 ≈0.86초 간격) 지나가므로, 너무 성기게
        // 폴링하면(예: 100ms) 그 사이에 있던 깊이 프레임을 그냥 지나칠 수 있다.
        let deadline = Date().addingTimeInterval(depthTimeout)
        while Date() < deadline {
            if session.status.hasDepth { return .a }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return .b
        #else
        // macOS 에는 ARFaceTrackingConfiguration 이 없다 — 항상 B(일반 카메라).
        return .b
        #endif
    }
}
