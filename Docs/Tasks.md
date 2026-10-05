# 코르소나 (Coursona) — Tasks

상태: ✅ 완료 · 🔄 진행 · ⏳ 대기 · 🧪 실기기 검증 필요 · 🔬 스파이크(결과에 따라 설계 분기)

원칙(초상 계승): 마일스톤 끝에 4개 빌드(iOS 시뮬·iPadOS 시뮬·macOS·iPhone/Mac 실기기) 통과 + 체크리스트. 근거 문서는 `Docs/TechPRD.md` v0.2(절 번호는 거기 기준), UI 근거는 `Docs/UXPRD.md`. **2026-10-05 밤 구현 착수.** Combine 금지 아님(TechPRD §6.1 예외).

## C0 · 프로젝트 셋업

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-001 | Xcode 프로젝트 `Coursona`: iOS·iPadOS·macOS 한 타깃(family 1,2 + Mac), 번들 `com.coulson.Coursona`, 배포 iOS 26·iPadOS 26·macOS 26, 엔타이틀먼트(카메라·마이크·로컬 네트워크·사진 보기) | §3, §8 | ✅ — `UpdateTargetBuildSetting`/`AddInfoPlist` 로 설정(SUPPORTED_PLATFORMS 에서 xros/xrsimulator 제거, family 1,2, 배포 26.0, bundle id, `ENABLE_RESOURCE_ACCESS_CAMERA/AUDIO_INPUT`, `ENABLE_INCOMING/OUTGOING_NETWORK_CONNECTIONS`, `ENABLE_USER_SELECTED_FILES=readwrite`, Info.plist 카메라·마이크·로컬네트워크·Bonjour `_coursona._tcp`). macOS·iPhone 시뮬·iPad 시뮬 3빌드 확인(🧪 실기기 보류, 연결된 기기 없음). `DEVELOPMENT_TEAM` 은 손대지 않음(pbxproj 직접편집 금지 하네스 규칙) |
| T-002 | 로컬 Swift Package `CoursonaKit` — 초상 `ChosangKit` 소스를 **파일 단위로 복사**해 모듈 리네임: Core·Capture·Fit·Face(신규)·Texture·Splat(신규)·Rig·Drive(신규)·IO·ML(신규), 테스트 타깃 포함. 초상 리포를 경로로 참조하지 않는다 | §6.1 | ✅ — 73개 파일 복사+리네임(Chosang→Coursona, chosang→coursona), Face/Splat/ML/Drive 는 계획 주석만 담은 플레이스홀더 타입으로 신설. **미연결**: 앱 타깃이 아직 이 패키지에 의존하지 않음 — Xcode가 열려 있을 때 패키지 의존성 추가는 pbxproj 를 건드려 하네스가 막음. 사용자가 Xcode 에서 File ▸ Add Package Dependencies ▸ Add Local… 로 `CoursonaKit` 폴더를 선택하고 앱 타깃에 `CoursonaKit` 제품을 추가해야 함(한 번만) |
| T-003 | 템플릿 반입: `Default.chosangtemplate`(template.json·bust.mesh·Template.usdz·textures·clips)만 복사. `EyesMouth.usdz`·`mouthInnerShapes` 메타는 **쓰지 않는다**(참조하지 않도록 로더에서 가드) | §6.2 | ✅ — 초상 번들을 풀어 `EyesMouth.usdz` 제외 후 `coursona/coursona/Resources/Templates/Default.coursonatemplate`(stored zip, 24파일, 30MB)로 재압축. `tools/make_default_template.sh` 도 같은 방식으로 추가(재생성용) |
| T-004 | 초상에서 포팅한 테스트 스위트 전체(`FitTests`·`SelfFitTests`·`TextureBuilderTests`·`TextureRegionsTests`·`SparseCaptureTests`·`CaptureGuideTests` 등)를 기준선으로 `swift test` 녹색 확인 | §9 | ✅ — `swift test`: **82개 테스트, 18개 스위트 전부 통과**(157초, Metal 패리티 포함) |
| T-005 | `TierClassifier`: `ARFaceTrackingConfiguration.isSupported` + 2초 내 `capturedDepthData` 수신 → A, 실패 시 B(iOS/macOS 공통), 사용자가 "사진 1장"을 고르면 C. 세 진입점을 **막지 않는다** | §3, §5 | ✅ — `CoursonaCapture/TierClassifier.swift`. macOS 빌드로 `#else` 분기만 검증, iOS 분기(`#if os(iOS)`)는 패키지 단독으로는 iOS SDK 크로스빌드를 안 해 **미검증**(T-002 연결 뒤 앱 빌드로 확인) |
| T-006 | 4개 빌드(iOS 시뮬·iPadOS 시뮬·macOS·실기기 1종) 통과 | — | 🔄 — 3/4(iOS 시뮬 iPhone 17, iPadOS 시뮬 iPad Pro 11, macOS 전부 성공). 실기기는 연결된 기기가 없어 🧪 보류 |

## C1 · 한 메시·투명 흉상

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-101 | `FaceSurfacePartitioner`(CoursonaCore): 얼굴면(ARKitFace∪LidInner∪LipInner∪캡 신규 정점) 삼각형을 앞쪽으로 재배열, 코너 UV 도 같이 재배열 | §6.2 | ✅ |
| T-102 | `CapBuilder` v0(템플릿 좌표): **설계 변경** — 블렌더 `eye_band`/`mouth_band` 상수를 추측 재현하는 대신, `Geometry.boundaryLoops`(경계 변 위상 탐색)로 눈·입의 실제 열린 테두리를 직접 찾아 중간 고리(신규)+중심(신규)으로 닫는다. 시드(눈·입 중심)로부터 20mm 안의 가장 가까운 경계 고리만 닫아 목/어깨 절단면과 혼동하지 않는다. 구멍이 없는 템플릿(합성 등)은 조용히 건너뛴다 | §6.2, §6.4 F6 | ✅ |
| T-103 | `BustEntity` 파트 렌더: `LowLevelMesh.Part` 2개(머티리얼 인덱스 0=얼굴면, 1=나머지), 나머지는 기본 opacity 0(완전 제외), `setGhostVisible(true)` 로 0.15 고스트 토글 | §6.2, §3 | ✅ |
| T-104 | 단위 테스트(`FaceSurfaceTests`, 평면 격자로 알고리즘 검증 — 실제 bust.mesh 는 앱 리소스라 패키지 테스트에서 직접 못 읽음): 경계 고리 탐색, 시드 매칭(먼 구멍은 안 닫음), 캡 자기 일치(정점·삼각형 수가 공식과 정확히 일치), 워터타이트(닫은 뒤 그 구멍의 경계 0) | §9 | ✅ — `swift test` 86개 전부 통과(신규 4개 포함) |

## C2 · 얼굴면 완성 (A 등급 밀집 경로)

| ID | 작업 | 근거(F-단계) | 상태 |
|---|---|---|---|
| T-201 | `EyeOpeningSolver`(F2) | F2 | ✅ — **새 코드 불필요**. `FacePatchSolver.estimateEyes`(C0 에서 이미 포팅됨)가 눈꺼풀 링 사전값+대수적 구 피팅으로 이미 이 일을 한다. 눈 감기 컷으로 보강하는 부분만 **C3 에서 추가**(그 컷 자체가 아직 캡처되지 않음) |
| T-202 | `SilhouetteFitter` 제외 영역(F4): `SilhouetteOptions.excludeEyeMouthRegion`(기본 ON) — 움직일 정점에서 LidInner∪LipInner 제외(`movableVertices`), 포인트 클라우드에서 눈·입 중심 반경 안 깊이점 제외(`exclusionCenters`) | F4 | ✅ |
| T-203 | ~~`InnerBandBuilder`(F5)~~ | F5 | ✅ — **불필요해짐**. LidInner·LipInner 는 C1 에서 건드리지 않는다(기존 위치·삼각형 그대로). "인덱스↔루프 순서 추론"(`InnerBandIndexMap`)은 설계 자체가 사라졌다 — §6.2 구현 노트 참고 |
| T-204 | `CapBuilder` v1(F6): 피팅 좌표로 다시 닫기 | F6 | ✅ — **새 코드 없이 됨**. `BustEntity.init` 이 `identity.positions`(정점 수가 맞으면)를 템플릿에 대입한 뒤 **같은** `CapBuilder.addingCaps` 를 부른다. `caps.json` 은 **불필요**(무상태 재계산이라 저장할 게 없다) |
| T-205 | `UserShapeDeltas`(F7) | F7 | ✅ — C3 에서 `ShotKind.eyesClosed`/`mouthOpen` 이 생겨 재개. 그 컷의 정렬된 ARKit 패치에서 다른 셰이프 기여를 뺀 뒤 가중치로 나눠 `eyeBlinkLeft/Right`·`jawOpen` 패치 델타를 **직접 치환** — 미소 기반 진폭 스케일(`DeltaCalibrator.jawOpen`)보다 정확하다(합성 테스트: 모양이 단순 배율이 아닐 때 스케일 보정은 설명을 못 해 RMS 3.0mm, F7 은 단일 컷 캡처 노이즈 바닥치인 0.75mm). `FitOptions.calibrateUserShapes`(기본 on)로 끌 수 있다 |
| T-206 | `RegionDeltaBuilder`(F8): 캡이 새로 만든 정점(중간 고리·중심)에 **붙어 있는 테두리의 평균 델타**를 준다 — `CapBuilder.addingCaps` 안에서 셰이프마다 수행 | F8 | ✅ |
| T-207 | `SelfIntersectionCheck`(F9): 진짜 삼각형-삼각형 교차 대신 **법선 뒤집힘**으로 근사(캡 삼각형이 중립↔셰이프 1.0 사이에서 뒤집히면 겹침 의심) | F9 | ✅ — `CoursonaFace/SelfIntersectionCheck.swift`. 4종 분류(눈 띠↔캡 등)·재시도 로직은 v1 범위에서 뺐다(근사 검사라 재시도할 "상수"가 없다) |
| T-208 | ~~`Identity` → identity.bin v3~~ | §6.7 | ✅ — **불필요해짐**. 캡·F8 델타는 (템플릿, 피팅된 positions) 만으로 로드 시 결정적으로 재계산된다 — 저장할 사용자별 데이터가 없다. identity.bin 은 v2 그대로 |
| T-209 | `coursona-validate --fit`: 자기교차 지표 출력 | §6.9 | ✅ — 피팅 좌표로 캡을 다시 닫고 캡별 테두리 크기 + `SelfIntersectionCheck` 결과를 출력 |
| T-210 | 🧪 합성 번들 자기교차 0, 실기기 A 번들(iPhone) 자기교차 0 | §9 | 🔄 — 단위 테스트(평면 격자 픽스처)로 F8 평균 델타·F9 뒤집힘 검출 확인(`FaceCompletionTests`, 4개 전부 통과). 실제 템플릿·실기기 번들 확인은 🧪 보류(실기기 없음) |

## C3 · 캡처 A/B/C

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-301 | `FaceCaptureSession` 7컷(필수 5+선택 2), `AVDepthData.cameraCalibrationData` 저장, 저장 시 5/5 깊이 검증 | §6.3 A | 🔄 — `ShotKind`에 `eyesClosed`/`mouthOpen`(선택, `isOptional`) 추가, `FaceFrameStatus.eyeBlinkAvg`/`jawOpenWeight` + `CaptureGate` 임계값으로 두 컷 게이팅 완료(F7 이 바로 이 컷을 씀). **저장 시 5/5 깊이 검증**도 완료: `CoursonaCapture/DepthCoverage.swift`(필수 5컷 중 깊이 없는 컷을 집어 한글 안내 문장까지 냄, `coursona-validate --fit` 에도 연결), 단위 테스트 4개. `cameraCalibrationData` 저장은 **의도적으로 미룬다** — `DepthRegistration`(C0 포팅분)이 이미 경험적 오프셋 보정으로 잘 동작하고, calibration 데이터의 실제 필드 해석(좌표 규약·부호)은 TrueDepth 실기기 없이 검증할 방법이 없어 섣불리 손대면 초상의 회전 버그 같은 걸 또 만들 위험이 크다 — 🧪 실기기 확보 후 재검토 |
| T-302 | `PhotoCaptureSession` 확장: B 등급 5+2컷, `GeneratePersonSegmentationRequest(.accurate)` 매트, `VNDetectFaceCaptureQualityRequest` 점수 게이트 | §6.3 B | ✅ — Vision 눈/입 랜드마크 바운딩박스로 `eyeAspectRatio`/`mouthOpenRatio` 게이팅(선택 2컷) 완료. 캡처 품질 점수는 `DetectFaceCaptureQualityRequest`(score ≥ 0.5) 로 게이팅. 인물 매트는 `GeneratePersonSegmentationRequest` 로 받지만 **전체 매트 이미지 저장은 안 한다** — 그 접근자(`pixelBuffer`)가 이 배포 타깃(OS 26)보다 높은 OS 27+ 가 필요함을 `RunCodeSnippet` 으로 직접 확인했다. 대신 OS 26 에서 이미 되는 `pixel(at:)` 로 얼굴 상자를 그리드 샘플링해 "상자가 실제로 사람인가" 게이트로만 쓴다(`PersonCoverage.swift`, 순수 로직 분리로 단위 테스트 5개). 배경 제거용 실제 매트 파일 저장은 OS 27 배포 타깃으로 올릴 때 재검토 |
| T-303 | C 등급: `PhotosPicker`/파일 가져오기 → 정면 1장 적합성 검사(정면·눈 뜸·입 다묾·밝기) | §6.3 C | 🔄 — `CoursonaCapture/PhotoSuitability.swift`: 평가 로직은 Vision 비의존 순수 함수(B 등급과 **같은 `PhotoCaptureGate` 임계값** 재사용, 새 상수 없음) + `check(_:)`(Vision 래퍼). 단위 테스트 8개. `PhotosPicker` SwiftUI 연결은 C8 화면 작업 때 |
| T-304 | `VisionCorrespondence`: 템플릿 패치를 가상 카메라로 투영해 Vision 76점 영역과 최근접 대응 생성·캐시 | §6.3 | ⏳ |
| T-305 | `CoursonaML.MonoDepthEstimator`: Depth Anything V2 small(Core ML, Apple 배포) 래퍼, 지연 로드·CPU 폴백, 얼굴 박스 영역만 추론 | §6.10, Q7 | ⏳ |
| T-306 | iPad 가로 거치 대응: `CaptureShotMeta.orientation` 기록, 피팅은 메타만 사용(초상 회전 버그 재발 방지) | §6.3 | ✅ — `CaptureOrientation`(7종) 추가, `FaceCaptureSession`(A 등급)이 `UIDevice.current.orientation` 을 그대로 기록만 한다. **캡처·피팅 회전 수학은 전혀 안 건드렸다** — 지금도 늘 세로로 처리한다(초상 회전 버그가 바로 이 수학을 실기기 없이 건드려서 난 문제라 가장 조심한 부분). `beginGeneratingDeviceOrientationNotifications()` 를 안 부르면 이 값이 항상 0(.unknown)이라는 게 문서에 명시돼 있어 `start()`/`stop()` 에 추가(실기기 없이는 몰랐을 함정). Codable 왕복 단위 테스트 3개. 실제 가로 지원(영상·깊이 회전 분기)은 이 기록을 보고 나중에 결정 |
| T-307 | 🧪 실기기 체크리스트 1차: iPhone A 7컷 완주, Mac B 5컷 완주 | §9 | 🔄 — 2026-10-05, iPhone 16·MacBook Air M4 에서 `TierClassifier` 1차 실기기 확인(ContentView 자리표시자 수준, 7컷 캡처 UI 는 아직 없음). Mac 은 기대대로 B. iPhone 16 은 처음 두 번 TrueDepth 가 있는데도 B 로 나왔으나, **임시 진단 화면(실시간 미리보기 + 상태 표시)으로 직접 확인한 결과 최종적으로 A 로 정확히 판정됨 — `TierClassifier` 로직 자체는 처음부터 맞았다.** 진짜 원인은 지금의 `ContentView`(자리표시자) 가 라이브 카메라 미리보기 없이 백그라운드에서 조용히 2초만 보고 끝나는 구조라, 사용자가 그 2초 동안 카메라를 보고 있지 않으면(안내가 전혀 없으니 당연하다) 얼굴이 안 잡혀 B 로 떨어지는 **테스트 방법론 문제**였다. 권한이 `.notDetermined` 면 먼저 묻고 기다리게 한 수정은 유효한 개선으로 남겨둔다. **중요한 제품 요구사항 하나 확정**: C8 에서 실제 캡처 진입 화면을 만들 때는 반드시 라이브 미리보기(혹은 최소한 "카메라를 봐주세요" 안내)를 등급 판정 중에 같이 보여줘야 한다 — 지금처럼 안내 없이 조용히 판정하면 실사용자도 똑같이 헷갈릴 것이다 |

## C4 · 단안 피팅 (B·C 등급)

| ID | 작업 | 근거(M-단계) | 상태 |
|---|---|---|---|
| T-401 | `MonoFitter` M1–M6: Vision 8점 대응 → 자세·스케일(s=1) → 광선 삼각측량(다시점) → 3D 바이하모닉 RBF 패치 변형 → 목 감쇠·대칭 → F2 이하 공통 단계 합류 | M1–M6 | ✅ — **새 코드 불필요, C0 포팅분이 이미 함**. `SparseFitter`(초상에서 포팅) + `FaceFitter.fit` 의 자동 분기(`bundle.meta.sparse` 면 `SparseFitter` 로)로 이미 동작한다. TPS 대신 바이하모닉 RBF, "2변수 최소제곱 의사 깊이" 대신 **광선 삼각측량**(여러 컷의 랜드마크 광선 교점)을 쓴다 — 수학은 다르지만 역할은 같다. T-304(Vision 76점 전체 대응)는 지금의 8점(눈꼬리 4·코끝·입꼬리 2·턱) 보다 더 조밀한 대응을 주는 **품질 개선**이지 이 경로의 전제조건이 아니다 — 8점만으로 이미 아래 T-402 정확도를 만족한다 |
| T-402 | 단위·합성 테스트: 76점 재투영 RMS < 2px, 의사 깊이 정합 잔차 중앙값 < 4mm, 자기교차 0 | §9 | ✅ — `SparseCaptureTests`·`FitTests`(`sparseFit`·`sparseFitMultiShot`) 가 이미 확인: 섭동 사용자 턱 이동 오차 < 1mm, 다시점 코 깊이 오차 0.37mm(정면 단일 컷 9.28mm 대비) · 재투영은 `quality.notes` 에 px 단위로 기록됨. 자기교차는 C2 의 `SelfIntersectionCheck` 가 피팅 등급과 무관하게(CapBuilder 는 Identity.positions 만 본다) 같은 경로로 통과 |
| T-403 | 🧪 Mac 실기기(FaceTime HD) B 등급 빌드 1회 | §9 | ⏳ — 실기기 필요, 보류 |

## C5 · 텍스처·스플랫

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-501 | `TextureBuilder` `faceOnly` 프리셋: 얼굴 UV + 캡 UV 섬(아틀라스 여백 우선, Q8) | §6.5 | ✅ — 캡 UV 섬(선행) + `TextureBuildOptions.faceOnly`/`faceOnlyPreset(size:splatColorSize:)` 둘 다 완료. `faceOnly` 켜면 얼굴 패치·눈꺼풀/입술 안쪽·캡(`capResult.caps` 의 `triangleIndexRange` 로 바로 식별, 새 분류 불필요) 삼각형만 전체 해상도 누적을 받고, 나머지는 그 단계에서 샘플링 자체를 건너뛴다(관측 0 으로 남아 **기존** 4단계 채움이 그대로 메운다 — 새 채움 코드 없음). 나머지 영역 색은 `TextureBuildResult.splatColor`(기본 512², 접합·페더 없이 컷 가중 평균만 — 스플랫은 이산적이라 이음매가 안 보임)로 따로 낸다. Metal 백엔드는 이 옵션을 몰라 패리티가 깨지므로 `faceOnly` 켜지면 CPU 로 강제한다. 단위 테스트 4개(splatColor 유무·크기·내용, 관측↔채움 비율 역전, 얼굴 영역 품질 유지 확인) |
| T-502 | 눈 캡·입 캡 텍스처 투영(정면 중립 컷의 눈, 입 벌림 컷의 치아·입안) | §6.5 | 🔄 — **전용 투영 코드 없이 됨**. `TextureBuilder.build`/`probe` 가 1단계(기하)에서 `CapBuilder.addingCaps` 로 눈·입 구멍을 먼저 닫도록 수정(`BustEntity` 와 같은 패턴: 피팅된 좌표 대입 → 캡 닫기 → 그 결과로 렌더 메시 생성). 캡 삼각형도 그 뒤부터는 다른 모든 영역과 **같은** 다중 컷 카메라 투영·누적·채움 파이프라인을 그대로 받는다 — T-501 의 캡 UV 섬이 있으면 그 섬에, 없으면 바깥 고리 UV(상속)에 투영된 색이 쌓인다. 구멍 없는 템플릿(지금의 합성 템플릿)은 캡이 전부 nil 이라 동작·출력이 기존과 완전히 같다(기존 테스트 118개 전부 그대로 통과로 확인). `CoursonaTexture` 가 `CoursonaFace` 에 새로 의존(순환 없음: Texture→Face→Fit→Core). **검증 안 된 부분**: 구멍이 실제로 있는 템플릿으로 끝까지 돌려 캡 섬에 진짜 눈·입 내용물이 투영되는지는 아직 전용 테스트가 없다 — `SyntheticTemplate`(구멍 없음) 을 바꾸는 건 다른 테스트 다수가 그 모양에 의존해 위험이 커서 보류, 실제 블렌더 템플릿이 생기면 `coursona-validate --texture` 로 눈으로 확인 |
| T-503 | `CoursonaSplat`: 얼굴면 밖 삼각형 바인딩(≤60k), 색·불투명도 초기화, `splats.bin` | §6.6 | ✅ — `SplatBinder.build`: `BustEntity`/`TextureBuilder` 와 같은 패턴(피팅 좌표 대입 → `CapBuilder.addingCaps`)으로 캡을 닫고, `TextureBuilder.isFaceTri` 와 같은 정의의 "얼굴면 밖" 삼각형마다 면적 비례 1~3개(무게중심 쪽으로 치우친 바리센트릭, 외접원 반지름 기준 스케일·접평면 회전) 바인딩, 총합이 `maxSplats`(기본 60k) 넘으면 균등 솎아냄. 목·어깨 1.3배, 두피 2겹(`scalpLayers`), 얼굴면과 정점을 공유하는 바깥 2겹(`rimRings`, BFS)은 완전 불투명. 색은 `TextureBuilder`(`faceOnlyPreset`)의 `splatColor` 에서 샘플링, 관측 없으면(알파 0) 영역 기본색(지금은 피부색 하나로 통일 — "어깨 옷 평균" 은 옷 텍스처 소스가 없어 피부색으로 대체, 아래 노트) 로 떨어진다. `splats.bin`(`SplatFile`, magic `CSP1`)은 BustMeshFit 과 같은 이진 규칙, "데이터"(렌더용 14 float+패딩)·"바인딩"(tri·u·v·offset, 변형 시 재계산용) 두 블록을 분리 저장. 단위 테스트 10개(`SplatBinderTests` 6 + `SplatFileTests` 4) |
| T-504 | `GaussianSplatResource.BufferResource` 브리지, 시뮬레이터·실패 시 고스트 메시 폴백 | §6.6 | ⏳ |
| T-505 | 🧪 성능: iPhone 15 Pro 60fps(얼굴면+60k 스플랫), 스플랫 초기화 ≤ 2s | §7 | ⏳ |
| T-S1 | 🔬 SHARP 스파이크(Mac 전용, `coursona-spike` 타깃, 제품 번들 제외): 정면 사진 → SHARP 3DGS ↔ §6.6 자체 초기화 비교, 결과는 `Docs/Spikes.md` 수치·그림만 | §6.6 스파이크, Q9 | ⏳ |

## C6 · 라이브 구동

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-601 | `ARKitFaceDriver`(iOS·iPadOS): 초상 라이브 경로 재사용, ARKit 52 + 고개 | §6.8 | ⏳ |
| T-602 | `VisionFaceDriver`(Mac 기본, iOS 폴백): 12 셰이프 + yaw/pitch/roll, 1€ 필터, 2초 중립 캘리브레이션 | §6.8, Q10 | ⏳ |
| T-603 | `MicVisemeDriver` 통합(`HangulViseme`·`MicLevelMeter`), Vision이 입을 못 잡을 때 보완 | §6.8 | ⏳ |
| T-604 | `FaceRigSystem` 합성 규칙 포팅(클립⊕라이브⊕비셈⊕깜빡임), 시선은 눈 캡 UV 이동 | §6.7, §6.8 | ⏳ |
| T-605 | 🧪 거울 화면 지연 실측 < 120ms, iPhone 60fps·Mac 90fps | §7, §9 | ⏳ |

## C7 · 패키지·병합·플랫폼 동일성

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-701 | `.coursona` manifest schema 2(`tier`·`faceSurface`·`quality.selfIntersections`·`splats`·`scaleKnown`), `caps.json`·`splats.bin` 포함 | §6.9 | ⏳ |
| T-702 | 전송: 초상 `ChosangTransfer` 서비스명 `_coursona._tcp`, 세 플랫폼 양방향, `.chosang` 열기 호환 | §6.9, Q4 | ⏳ |
| T-703 | 열기(모든 플랫폼): 템플릿 id·버전·정점 수 검사 후 Identity·캡·알베도·**스플랫까지 전부** 복원(초상 알베도 미복원 추정 결함 수정) | §6.9 | ⏳ |
| T-704 | 업그레이드 병합: B/C → A 재빌드 시 이름·머리카락 선택·탈조명 강도 유지, A→B 역방향 경고 | §6.9, §5 | ⏳ |
| T-705 | 🧪 iPhone(A)로 만든 패키지를 iPad·Mac에서 열어 정면·좌30°·눈감기·입벌림·시선 5장 스냅샷이 **세 플랫폼에서 일치**하는지 확인 | §9 | ⏳ |

## C8 · 검수·마감

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-801 | 검수 화면 구현(`Docs/UXPRD.md` 화면 4), 품질 카드 + FoundationModels 한 줄 설명(실패 시 고정 문구) | §6.10, UXPRD §5-4 | ⏳ |
| T-802 | 렌더 스냅샷 회귀 테스트(정면·좌30°·눈감기·입벌림·시선, 픽셀 차이 < 2%) | §9 | ⏳ |
| T-803 | (선택, Q5) USDZ/PLY 내보내기 — 메뉴 항목으로만, Mac | §6.9 | ⏳ |
| T-804 | 🧪 실기기 체크리스트 전항(§9 전체) 통과 | §9 | ⏳ |

## 블렌더 쪽 제안(참고, 초상 리포는 수정하지 않음)

Q6 관련: `innerBands`(LidInner·LipInner 정점 ↔ 루프 순서 인덱스)와 눈·입 구멍을 처음부터 닫힌 메시로 내보내는 옵션을 `template.json`에 추가해 달라는 제안은 **문서로만** 남긴다(`Docs/Blender-요청-제안.md`, 작성은 사용자 결정). 코르소나는 그 전까지 앱 쪽 추론(`InnerBandIndexMap`)과 `CapBuilder`로 동작한다.

## 미결 사항 추적 (TechPRD §14)

| # | 질문 | 현재 기본값 | 이 태스크에 미친 영향 |
|---|---|---|---|
| Q1 | 선택 2컷(눈 감기·입 벌림) | 넣는다(건너뛰기 가능) | T-301·T-302·T-205 |
| Q2 | 투명 기본을 완전 제외 vs 옅은 고스트 | 완전 제외 | T-103 |
| Q3 | 스플랫 짧은 학습 v1 포함 여부 | 안 넣는다(v1.1) | C5 범위에서 제외 |
| Q4 | `.coursona` 신설 vs `.chosang` 유지 | `.coursona` 신설 + `.chosang` 열기 | T-701·T-702 |
| Q5 | Mac 내보내기(USDZ/PLY) v1 포함 여부 | 선택(C8 마지막) | T-803 |
| Q6 | 초상에 innerBands 제안 여부 | 제안 문서만 | T-203 |
| Q7 | Depth Anything V2 번들 동봉 vs 다운로드 | 동봉 | T-305 |
| Q8 | 캡 UV 섬: 아틀라스 여백 vs 전용 텍스처 | 아틀라스 여백 우선 | T-501 |
| Q9 | SHARP 스파이크 수행 여부 | 수행(C5 전, 하루 상한) | T-S1 |
| Q10 | Mac 라이브 셰이프 12종 제한 동의 | 동의 | T-602 |

## 실기기 체크리스트 (전 마일스톤 종료 시)

1. iPhone(A): 7컷 자동 촬영 → 빌드 90초 이내 → 검수에서 자기교차 0 → 거울에서 표정 반응.
2. iPad(A, 가로 거치): 7컷 완주, 방향 보정 정상.
3. Mac(B, FaceTime HD): 5컷 완주 → 빌드 60초 이내 → 거울 2초 캘리브레이션 → 입/눈썹/깜빡임 반응.
4. 사진 1장(C): 적합성 검사 → 빌드 30초 이내.
5. iPhone → Mac 전송 → 같은 패키지를 열었을 때 5장 스냅샷 일치.
6. B/C → A 업그레이드 병합 후 이름·머리카락 선택 유지 확인.
7. 시뮬레이터: 스플랫 폴백 고스트 메시 정상 표시.
