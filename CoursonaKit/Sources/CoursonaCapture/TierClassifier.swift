//
//  TierClassifier.swift
//  CoursonaCapture
//
//  입력 등급 A/B/C 판정 (TechPRD §3·§5, Tasks T-005). C(사진 1장)는 사용자가 "사진으로 만들기" 를
//  직접 선택했을 때만 들어가는 진입점이라 이 판정기의 대상이 아니다 — 여기서는 A/B 만 가른다.
//
//  규칙: `FaceCaptureSession.isSupported`(ARFaceTracking) 이고 **TrueDepth 카메라 하드웨어가 있으면** A.
//  둘 중 하나라도 아니면 B(이 기기 카메라, 치수 추정). 아무 기기도 막지 않는다 — 실패하면 그냥 B 로 떨어진다.
//
//  왜 하드웨어 검사인가: `ARFaceTrackingConfiguration.isSupported` 는 A12 이상이면 TrueDepth 가 없는 기기
//  (iPhone SE 2·3세대 등)에서도 true 라서, 그것만으로는 깊이(`capturedDepthData`)가 실제로 오는지 알 수 없다.
//  `AVCaptureDevice.default(.builtInTrueDepthCamera, …)` 는 그 센서가 있는지를 카메라를 켜지 않고 즉시 답해 준다.
//
//  🧪 이전 방식(ARSession 을 띄워 깊이 프레임이 오는지 최대 5초 기다리기)을 버린 이유 — 실기기(iPhone 16,
//  2026-10-06)에서 아래 증상으로 이어졌다:
//   - 시작 화면이 뜰 때마다 TrueDepth 세션을 켰다 끄느라 UI 가 잠깐씩 멈추고, 캡처 화면의 자기 세션과도 카메라를
//     두고 겹쳤다.
//   - 깊이 프레임은 **얼굴이 잡혀 있을 때만** 상태에 기록되므로(`FaceCaptureSession.status.hasDepth`), 앱을 켜고
//     카메라를 안 보고 있으면 5초 뒤 B 로 떨어졌다가, 시작 화면으로 돌아와 다시 판정될 때 A 로 바뀌었다
//     ("실행 시 B 로 보이다가 초기 화면으로 돌아오니 다시 스캔해 A 로 조정됨").
//   - 최초 실행에는 시작 화면에서 바로 카메라 권한 팝업이 떴다(판정이 권한을 요구해서). 지금은 하드웨어 검사만
//     하므로 권한은 실제 캡처에 들어갈 때(ARKit 이 세션을 켜며) 묻는다.
//
//  🧪 2차 회귀(iPhone 16, 2026-10-06): 위 수정 직후 이 함수를 **동기 함수**로 뒀더니, `.task { model.detectTier() }`
//  안에서 `AVCaptureDevice.default(...)` 가 중단점(await) 없이 메인 스레드에서 그대로 실행됐다. 이 호출은
//  미디어 서버에 물어보는 식이라 막 실행한 직후엔 응답이 늦어서, 그동안 메인 런루프가 막혀 터치가 쌓였다가
//  호출이 끝나는 순간(UIKit 접근성 시스템이 밀린 작업을 처리하며 "AX Safe category class ... not found" 로그를
//  찍는 시점과 겹쳐) 한꺼번에 반응했다. 그래서 다시 `async`로 두되, **폴링 루프 없이** 이 한 호출만
//  `Task.detached`로 메인 스레드 밖에서 실행한다 — "카메라를 켜지 않고 한 번만 확인한다"는 성질은 그대로다.
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
    /// 카메라를 켜지 않고 한 번만 확인한다 — 같은 기기에서는 항상 같은 값이라 호출자가 캐시해도 된다.
    /// `async`인 이유는 I/O 대기가 아니라 순전히 메인 스레드를 막지 않기 위해서다(위 2차 회귀 메모 참고).
    public static func detectAutomaticTier() async -> CaptureTier {
        #if os(iOS)
        guard FaceCaptureSession.isSupported else { return .b }
        let hasTrueDepth = await Task.detached(priority: .userInitiated) {
            AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
        }.value
        return hasTrueDepth ? .a : .b
        #else
        // macOS 에는 ARFaceTrackingConfiguration 이 없다 — 항상 B(일반 카메라).
        return .b
        #endif
    }
}
