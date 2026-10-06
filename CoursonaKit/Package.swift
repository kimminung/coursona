// swift-tools-version: 6.0
// 코르소나(Coursona) 로컬 패키지. 앱 타깃이 `CoursonaKit` 라이브러리 제품에 의존한다(아직 미연결 — T-002 메모 참고).
// 초상(Chosang) ChosangKit 을 복사해 모듈 리네임(T-002)한 것이 기반. 모듈 경계(TechPRD §6.1):
//   CoursonaCore     모델·포맷·ARKit 52 타입·수학 (Foundation/simd/CoreGraphics 만, 전 플랫폼) — 초상 그대로
//   CoursonaCapture  iPhone·iPad ARFaceTracking 캡처(A 등급) + AVCapture/Vision 캡처(B 등급) + MicLevelMeter — 초상 그대로, 등급 판정 추가
//   CoursonaML       Apple 제공 온디바이스 모델 래퍼(Depth Anything V2 small) — 신규, C3
//   CoursonaFit      피팅(Procrustes·패치 치환·RBF 전파·실루엣), 외형 힌트(FoundationModels), 단안 피팅(MonoFitter) — 초상 + C4 확장
//   CoursonaFace     얼굴면 완성(눈·입 캡, 자기교차 검사) — 신규, C2
//   CoursonaTexture  다시점 투영·접합·탈조명·채움 — 초상 그대로, 얼굴면이든 그 밖이든 같은 파이프라인(입체감 v3)
//   CoursonaRig      BustEntity(LowLevelMesh + LowLevelDeformation / CPU 폴백), FaceRig, ClipPlayer — 초상 그대로 + 파트 분할(C1)
//   CoursonaDrive    라이브 구동(ARKit/Vision/마이크 드라이버 합성) — 신규, C6
//   CoursonaIO       .coursona / 캡처 번들 읽기·쓰기, PNG, USD 내보내기(macOS), 전송(Bonjour+TLS) — 초상 그대로 + schema 2(C7)
//   CoursonaValidate 템플릿·클립 계약 검사 (CLI `coursona-validate` 가 사용) — 초상 그대로
//   CoursonaStudio   캡처 번들→피팅→텍스처→패키지 저장 오케스트레이션 — 신규, C8 UI 2단계(화면이 쓰는 앱 수준 API)
//
// 입체감 v3(2026-10-07): 얼굴면 밖(두피·목·어깨)을 가우시안 스플랫으로 따로 그리던 `CoursonaSplat` 모듈(SplatBinder·
// PhotoSplatBuilder·SplatGPUBridge·SplatFile)을 제거했다 — 실기기에서 "메시+스플랫 점구름+눈알" 세 겹이 따로
// 보이는 문제로, 얼굴면과 같은 텍스처 투영 기술로 머리부터 어깨까지 하나의 메시·하나의 텍스처로 통일했다
// (`CoursonaTexture.TextureBuilder` 의 `faceOnly` 없는 전체 경로, `CoursonaRig.BustEntity` 가 그 "나머지" 파트에
// 얼굴과 같은 머티리얼을 쓴다). 되살릴 일이 있으면 git 이력에서 `CoursonaSplat/`·`CoursonaStudio/PersonMatte.swift`
// 를 찾으면 된다.
//
// 규칙: 순수 모델·수학(CoursonaCore)은 Foundation/simd/CoreGraphics 만. 비동기는 async/await 기본,
// 연속 신호(라이브 구동 등)엔 Combine 허용(TechPRD §6.1 — 초상과 달리 이 프로젝트는 Combine 을 금지하지 않는다).
import PackageDescription

let package = Package(
    name: "CoursonaKit",
    defaultLocalization: "ko",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(
            name: "CoursonaKit",
            targets: [
                "CoursonaCore", "CoursonaCapture", "CoursonaML", "CoursonaFit", "CoursonaFace",
                "CoursonaTexture", "CoursonaRig", "CoursonaDrive", "CoursonaIO", "CoursonaValidate", "CoursonaStudio",
            ]
        ),
        .executable(name: "coursona-validate", targets: ["coursona-validate"]),
    ],
    targets: [
        .target(
            name: "CoursonaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaCapture",
            dependencies: ["CoursonaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaML",
            dependencies: ["CoursonaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaFit",
            dependencies: ["CoursonaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaFace",
            dependencies: ["CoursonaCore", "CoursonaFit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaTexture",
            // CoursonaFace(C5, T-502): TextureBuilder 가 내부에서 캡(눈·입)을 닫아 그 UV 섬까지 같은 파이프라인으로 투영한다.
            dependencies: ["CoursonaCore", "CoursonaFace"],
            // Metal 커널 소스는 리소스로 복사해 런타임에 컴파일한다 (MetalTextureBackend)
            resources: [.copy("Shaders")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaRig",
            dependencies: ["CoursonaCore", "CoursonaFace"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaDrive",
            // CoursonaCapture(C6, T-602): VisionFaceDriver 가 B 등급 캡처와 같은 `PhotoCaptureSession` 카메라·Vision
            // 파이프라인을 그대로 돌려 쓴다(중복 Vision 호출 없이).
            dependencies: ["CoursonaCore", "CoursonaRig", "CoursonaCapture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaIO",
            dependencies: ["CoursonaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaValidate",
            dependencies: ["CoursonaCore", "CoursonaIO"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CoursonaStudio",
            dependencies: ["CoursonaCore", "CoursonaFit", "CoursonaTexture", "CoursonaIO"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "coursona-validate",
            dependencies: ["CoursonaCore", "CoursonaIO", "CoursonaValidate", "CoursonaTexture", "CoursonaRig", "CoursonaFit", "CoursonaFace", "CoursonaCapture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoursonaKitTests",
            dependencies: ["CoursonaCore", "CoursonaFit", "CoursonaFace", "CoursonaTexture", "CoursonaIO", "CoursonaValidate", "CoursonaCapture", "CoursonaDrive", "CoursonaStudio"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
