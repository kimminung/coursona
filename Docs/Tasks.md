# 코르소나 (Coursona) — Tasks

상태: ✅ 완료 · 🔄 진행 · ⏳ 대기 · 🧪 실기기 검증 필요 · 🔬 스파이크(결과에 따라 설계 분기)

원칙(초상 계승): 마일스톤 끝에 4개 빌드(iOS 시뮬·iPadOS 시뮬·macOS·iPhone/Mac 실기기) 통과 + 체크리스트. 근거 문서는 `Docs/TechPRD.md` v0.2(절 번호는 거기 기준), UI 근거는 `Docs/UXPRD.md`. 디자인(Persona 재현 에셋) 근거는 디자인 PRD — 아래 **D 절**. **2026-10-05 밤 구현 착수.** Combine 금지 아님(TechPRD §6.1 예외).

## C0 · 프로젝트 셋업

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-001 | Xcode 프로젝트 `Coursona`: iOS·iPadOS·macOS 한 타깃(family 1,2 + Mac), 번들 `com.coulson.Coursona`, 배포 iOS 26·iPadOS 26·macOS 26, 엔타이틀먼트(카메라·마이크·로컬 네트워크·사진 보기) | §3, §8 | ✅ — `UpdateTargetBuildSetting`/`AddInfoPlist` 로 설정(SUPPORTED_PLATFORMS 에서 xros/xrsimulator 제거, family 1,2, 배포 26.0, bundle id, `ENABLE_RESOURCE_ACCESS_CAMERA/AUDIO_INPUT`, `ENABLE_INCOMING/OUTGOING_NETWORK_CONNECTIONS`, `ENABLE_USER_SELECTED_FILES=readwrite`, Info.plist 카메라·마이크·로컬네트워크·Bonjour `_coursona._tcp`). macOS·iPhone 시뮬·iPad 시뮬 3빌드 확인(🧪 실기기 보류, 연결된 기기 없음). `DEVELOPMENT_TEAM` 은 손대지 않음(pbxproj 직접편집 금지 하네스 규칙) |
| T-002 | 로컬 Swift Package `CoursonaKit` — 초상 `ChosangKit` 소스를 **파일 단위로 복사**해 모듈 리네임: Core·Capture·Fit·Face(신규)·Texture·Splat(신규)·Rig·Drive(신규)·IO·ML(신규), 테스트 타깃 포함. 초상 리포를 경로로 참조하지 않는다 | §6.1 | ✅ — 73개 파일 복사+리네임(Chosang→Coursona, chosang→coursona), Face/Splat/ML/Drive 는 계획 주석만 담은 플레이스홀더 타입으로 신설. **연결 완료(2026-10-06 확인)**: 사용자가 Xcode 에서 File ▸ Add Package Dependencies ▸ Add Local… 로 연결 — `project.pbxproj` 에 `XCLocalSwiftPackageReference`/`XCSwiftPackageProductDependency` + 앱 타깃 Frameworks 단계에 `CoursonaKit` 제품 링크 확인, 3플랫폼 빌드 통과 |
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
| T-307 | 🧪 실기기 체크리스트 1차: iPhone A 7컷 완주, Mac B 5컷 완주 | §9 | 🔄 — 2026-10-05, iPhone 16·MacBook Air M4 에서 `TierClassifier` 1차 실기기 확인(ContentView 자리표시자 수준, 7컷 캡처 UI 는 아직 없음). Mac 은 기대대로 B. iPhone 16 은 처음 두 번 TrueDepth 가 있는데도 B 로 나왔으나, **임시 진단 화면(실시간 미리보기 + 상태 표시)으로 직접 확인한 결과 최종적으로 A 로 정확히 판정됨 — `TierClassifier` 로직 자체는 처음부터 맞았다.** 당시 결론: 라이브 미리보기 없이 조용히 2초만 보고 끝나는 구조라 사용자가 카메라를 안 보고 있으면 B 로 떨어지는 **테스트 방법론 문제**라고 판단, `ContentView`에 판정 중 "카메라를 봐주세요…" 안내를 추가했다.
  **2026-10-06, 그 수정으로도 또 B 가 나옴 — 가설이 틀렸음을 실기기 콘솔 로그로 직접 확인**: 이번엔 Xcode 가 실기기(연결된 iPhone)에 직접 빌드·설치·실행해 콘솔 로그를 받아봤다(`GetConsoleOutput`). `TierClassifier` 에 임시 진단 로그를 심어 보니 **얼굴 추적(`isTracked`)은 0.5초 안에 바로 되는데도** `capturedDepthData` 가 붙은 프레임 자체가 평균 ≈0.86초 간격으로 드물게 온다는 걸 확인(20ms 폴링 6초 동안 281회 중 7회만 깊이 있음, 두 차례 측정에서 첫 깊이 프레임이 각각 1.07초·3.64초만에야 나타남) — 즉 "카메라를 안 보고 있었다" 가 아니라 **옛 `depthTimeout=2.0` 자체가 TrueDepth 깊이 프레임의 실제 간격보다 짧았다**. `TierClassifier.detectAutomaticTier` 의 `depthTimeout` 을 5.0 초로 올리고 폴링도 100ms→20ms 로 좁혀 재측정 → 실기기에서 연속 2회 A 로 정확히 판정 확인. **중요한 제품 요구사항 하나 확정**(이전 결론 유지 + 보강): C8 실제 캡처 화면은 "카메라를 봐주세요" 안내뿐 아니라, 판정이 2초보다 훨씬 걸릴 수 있다는 것도 UI 에 반영해야 한다(예: 진행 표시를 5초 가정으로). 3플랫폼 + 실기기(iPhone) 빌드 전부 통과 |

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
| T-504 | `GaussianSplatResource.BufferResource` 브리지, 시뮬레이터·실패 시 고스트 메시 폴백 | §6.6 | ✅ — `SplatGPUBridge.makeComponent`: Apple 공식 "Creating a Splat Entity" 예제와 같은 레이아웃(인터리브 14 float, `LowLevelBuffer` + `BufferDescriptor` 5개)으로 `[SplatRecord]` → `GaussianSplatComponent`. **실제 빌드로 확인한 중요한 제약 둘**: ① `GaussianSplatComponent`/`GaussianSplatResource` 는 `@available(macOS 27, *)` — 이 프로젝트 배포 타깃(OS 26)보다 높다 ② **iOS SDK 에는 이 타입들이 아예 없다**("cannot find in scope", 가용성이 아니라 진짜 없는 심볼) — visionOS/macOS 전용으로 보인다. 그래서 실제 구현은 `#if os(macOS)` 로만 감싸고, `isSupported()`(OS 27 미만·iOS·Apple7 미만 GPU 전부 false)만 두 플랫폼 공통으로 열어 뒀다. 호출부는 `isSupported()` 가 false 면 고스트 파트 폴백으로 가면 된다. 단위 테스트 4개(macOS·OS27 에서만 돎, 이 개발 Mac 은 27.0.1 이라 실제로 돈다) |
| T-504b | `BustEntity` 배선: `applySplats(splatColor:fallbackSkin:options:)` — `SplatBinder.build`(캡 열기 전 원본 템플릿+Identity 보관, 캡 중복 방지) → `SplatGPUBridge.makeComponent` → 성공하면 `"BustSplats"` 자식 엔티티에 `GaussianSplatComponent` 붙이고 고스트 자동으로 끔(`setGhostVisible(false)`), 실패·미지원이면 고스트 폴백(`setGhostVisible(true)`) 하고 `splatsActive=false` | §6.6 | ✅ — `CoursonaRig` → `CoursonaSplat` 의존성 추가. `RunCodeSnippet` 로 이 개발 Mac(OS 27.0.1, Apple M3)에서 실제로 `applySplats()` 가 `true` 를 돌려주고 스플랫 자식이 붙는 것까지 확인(패키지 테스트가 아니라 앱 컨텍스트 — `BustEntity` 는 RealityKit·`@MainActor` 의존이라 기존에도 패키지 테스트 대상이 아니었던 것과 같은 이유, F5/F6 코드리뷰 검증 선례와 동일). 3플랫폼(Mac·iPhone 17 시뮬·iPad Pro 11 M5 시뮬) 빌드 통과 — iOS/iPadOS 는 `#if os(macOS)` 로 스플랫 분기 자체가 컴파일에서 빠지고 고스트 폴백만 남는다(T-504 의 플랫폼 제약 그대로 이어짐) |
| T-505 | 🧪 성능: iPhone 15 Pro 60fps(얼굴면+60k 스플랫), 스플랫 초기화 ≤ 2s | §7 | ⏳ |
| T-S1 | 🔬 SHARP 스파이크(Mac 전용, `coursona-spike` 타깃, 제품 번들 제외): 정면 사진 → SHARP 3DGS ↔ §6.6 자체 초기화 비교, 결과는 `Docs/Spikes.md` 수치·그림만 | §6.6 스파이크, Q9 | ⏳ |

## C6 · 라이브 구동

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-601 | `ARKitFaceDriver`(iOS·iPadOS): 초상 라이브 경로 재사용, ARKit 52 + 고개 | §6.8 | 🔄 — `CoursonaDrive/ARKitFaceDriver.swift`: `FaceCaptureSession`(A 등급)과 같은 `ArkitWeights(named:)` 변환 + `FacePoseConvention.guideAngles` 를 그대로 재사용해 ARSession `didUpdate frame:` 마다 52 가중치 + 머리 자세(yaw·pitch 만, roll 은 기존 규약 자체가 안 다룸)를 흘린다. **표정 가중치는 이미 실기기로 검증된 변환이라 신뢰도가 높지만, yaw/pitch 도(度) → 쿼터니언 합성(축·순서)은 라이브 구동에서 처음 쓰는 것이라 실기기 없이 못 검증했다** — T-306 의 "회전 수학을 실기기 없이 건드리면 위험하다" 교훈을 그대로 적용해 머리말에 🧪 로 명시. iOS 시뮬레이터 빌드 통과(ARKit 얼굴 추적 자체는 시뮬레이터에서 불가, 컴파일만 확인) |
| T-602 | `VisionFaceDriver`(Mac 기본, iOS 폴백): 12 셰이프 + yaw/pitch/roll, 1€ 필터, 2초 중립 캘리브레이션 | §6.8, Q10 | 🔄 — `CoursonaDrive/VisionFaceSignals.swift`(순수 로직, 단위 테스트 8개) + `VisionFaceDriver.swift`(상태 보유: `PhotoCaptureSession` 재사용 + 채널별 `OneEuroFilter`(신규, `CoursonaCore`, 단위 테스트 4개) + 2초 캘리브레이션). `PhotoCaptureSession`/`PhotoFrameStatus` 에 이번에 추가한 원시값(좌우 눈 종횡비·입 폭 비·안쪽 입술 종횡비·눈썹 거리·시선 오프셋)에서 12 특징(jawOpen·mouthSmile L/R·mouthPucker·mouthFunnel·eyeBlink L/R·browInnerUp·browDown L/R·eyeLook 8방향)을 중립 대비 상대값으로 뽑는다. **`RunCodeSnippet` 으로 실제 Mac 카메라를 켜 봤지만 카메라 권한이 `.notDetermined` 상태에서 그 실행 컨텍스트엔 권한 대화상자를 눌러줄 사람이 없어 추적 자체를 확인 못 했다** — T-307 의 "라이브 미리보기 없이 조용히 판정하면 안 된다" 교훈과 같은 종류의 한계. 순수 로직(`VisionFaceSignals`)은 합성 데이터로 검증됐지만, 실제 카메라 연동·임계값(완전히 감았을 때 EAR 비율 등은 전부 경험적 추정)은 실기기(또는 최소한 권한이 허용된 상호작용 실행)로 **아직 미검증** |
| T-603 | `MicVisemeDriver` 통합(`HangulViseme`·`MicLevelMeter`), Vision이 입을 못 잡을 때 보완 | §6.8 | ✅ — `CoursonaDrive/MicVisemeDriver.swift`(`MicLevelMeter`·`HangulViseme` 래퍼, 새 합성 로직 없음 — 입 합성은 이미 `FaceRigSystem` 에 있다) + `FaceDriverCoordinator.swift`(우선순위: ARKit > Vision(추적 중·캘리브레이션 끝남) > 마이크만 — 소반 `MouthSourceKind` 폴백과 같은 모양). 마이크만 경로에서는 `rig.externalWeights = nil` 로 둬서 `FaceRigSystem` 의 기존 오디오 기반 턱·비셈 합성이 그대로 입을 채우게 한다(새 코드 불필요) |
| T-604 | `FaceRigSystem` 합성 규칙 포팅(클립⊕라이브⊕비셈⊕깜빡임), 시선은 눈 캡 UV 이동 | §6.7, §6.8 | ✅ — 합성 규칙(`ExpressionMixer.mix`)·`FaceRigSystem` 자체는 **이미 포팅돼 있었다**(`CoursonaRig/FaceRig.swift`, 초상 `ChosangRig/FaceRig.swift` 와 바이트 단위로 동일 — T-002 때 같이 복사됨). 남은 절반(시선을 눈 캡 UV 이동으로)은 이번에 마저 끝냈다: `FaceSurfacePartitioner.partition`에 `capIndexRanges` 매개변수를 추가해 — 캡 삼각형을 정점 그룹 판정과 무관하게 항상 얼굴면으로 쳐서(간접 판정이 깨지는 걸 테스트로 잡아냄, 아래 참고) — 재배열 뒤 캡별 삼각형 구간(`capRanges`)을 돌려주게 했고, `BustEntity`가 그 구간으로 눈 왼쪽·오른쪽·입 캡을 각각 전용 `PhysicallyBasedMaterial`(눈: roughness 0.15 + clearcoat 0.6, 입: roughness 0.7)로 떼어낸 뒤 `applyGaze(_:)`로 `textureCoordinateTransform.offset`을 옮긴다(±0.08 UV, §6.7). `FaceRigSystem.update`의 `if let bust` 분기에 `bust.applyGaze(gazeFromWeights(rig.lastWeights))` 호출을 추가 — 라이브·합성 양쪽 다 최종 eyeLook 8방향 가중치에서 바로 뽑으므로 `rig.gaze`(레거시 각도 전용 상태)에 기대지 않는다. 캡 없는(구멍 없는) 템플릿은 기존 2-머티리얼 구조 그대로(회귀 없음, `RunCodeSnippet`으로 확인). 단위 테스트 1개 추가(`FaceSurfaceTests.capRangesAreRemappedCorrectly`) — 처음 짠 구현은 합성 테스트 픽스처(그룹이 비어 있음)에서 캡 삼각형 일부가 얼굴면 판정에서 누락되는 버그를 테스트가 바로 잡아냈다. 이 개발 Mac에서 `RunCodeSnippet`으로 실제 머티리얼 3개 분리·UV 오프셋 적용까지 확인(컴파일만 되고 안 돌려본 코드 아님) |
| T-605 | 🧪 성능·지연: 거울 화면 지연 < 120ms, iPhone 60fps·Mac 90fps | §7, §9 | ⏳ — 실기기 필요, 보류 |

## C7 · 패키지·병합·플랫폼 동일성

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-701 | `.coursona` manifest schema 2(`tier`·`faceSurface`·`quality.selfIntersections`·`splats`·`scaleKnown`), `caps.json`·`splats.bin` 포함 | §6.9 | 🔄 — `tier`·`splatCount`·`splats.bin` 저장/복원은 C8 UI 2단계(T-806)에서 미리 끝냈다(`PersonaBuildPipeline` 이 실제로 쓰는 걸 보니 뒤로 미룰 이유가 없었다). `CoursonaPackageStore.write`가 `splats.bin`(`SplatFile`)을 쓰고 `manifest.splatCount`를 채우며, `read`가 있으면 되읽는다 — 왕복 단위 테스트로 확인(`PersonaBuildPipelineTests`). 남은 것: `faceSurface`·`quality.selfIntersections`·`scaleKnown`·`caps.json` |
| T-702 | 전송: 초상 `ChosangTransfer` 서비스명 `_coursona._tcp`, 세 플랫폼 양방향, `.chosang` 열기 호환 | §6.9, Q4 | ⏳ |
| T-703 | 열기(모든 플랫폼): 템플릿 id·버전·정점 수 검사 후 Identity·캡·알베도·**스플랫까지 전부** 복원(초상 알베도 미복원 추정 결함 수정) | §6.9 | ⏳ |
| T-704 | 업그레이드 병합: B/C → A 재빌드 시 이름·머리카락 선택·탈조명 강도 유지, A→B 역방향 경고 | §6.9, §5 | ⏳ |
| T-705 | 🧪 iPhone(A)로 만든 패키지를 iPad·Mac에서 열어 정면·좌30°·눈감기·입벌림·시선 5장 스냅샷이 **세 플랫폼에서 일치**하는지 확인 | §9 | ⏳ |

## C8 · 검수·마감

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-801 | 검수 화면 구현(`Docs/UXPRD.md` 화면 5 "검수" — Tasks 구 표기 "화면 4"는 UXPRD 번호와 어긋나 정정), 품질 카드 + FoundationModels 한 줄 설명(실패 시 고정 문구) | §6.10, UXPRD §5-4 | ⏳ |
| T-802 | 렌더 스냅샷 회귀 테스트(정면·좌30°·눈감기·입벌림·시선, 픽셀 차이 < 2%) | §9 | ⏳ |
| T-803 | (선택, Q5) USDZ/PLY 내보내기 — 메뉴 항목으로만, Mac | §6.9 | ⏳ |
| T-804 | 🧪 실기기 체크리스트 전항(§9 전체) 통과 | §9 | ⏳ |
| T-805 | UI 1단계: 뼈대 — `DesignSystem/Theme.swift`(색상·`TierBadge`·`StatusPill`), `App/AppModel.swift`(`AppTab` 4개: 스튜디오·갤러리·정밀도·기기 연동), `RootView.swift`(탭 셸), `Views/StartTierView.swift`(화면 1), `Views/PermissionsView.swift`(화면 9), `Views/ComingSoonView.swift`(2~5단계 전 자리표시자) | UXPRD §3·§6 화면 1·9 | ✅ — 초상 `App/AppModel.swift`/`ContentView.swift` 의 `AppTab`+`TabView(selection:)` 패턴 그대로 재사용. `.preferredColorScheme(.dark)` 를 루트에 강제(UXPRD §7 기본 다크 테마) — 안 하면 iOS 에서 `.glassEffect()` 대비가 무너지는 걸 `RenderPreview` 로 실제 확인하고 고쳤다. 자리표시자이던 `ContentView.swift` 는 삭제(기능이 `StartTierView`로 흡수됨). Mac·iPhone 17 시뮬·iPad 시뮬·연결된 실기기(iPhone) 4곳 빌드 통과, 실기기에서 `RunProject`+`GetConsoleOutput` 으로 크래시 없음 확인, `RenderPreview` 로 Mac·iPhone·iPad 3곳 실제 렌더 확인(스크린샷 아님, MCP 도구로 직접 캡처) |
| T-806 | UI 2단계: `CoursonaStudio` 모듈 신설(`PersonaBuildPipeline`: 캡처 번들→피팅→텍스처→스플랫→패키지), `CaptureTier` 를 `CoursonaCore` 로 이동, `Views/CaptureGuideView.swift`(화면 2, 초상 `GuidedCaptureView.swift` 포팅), `Views/PhotoSuitabilityView.swift`(화면 3) | UXPRD §6 화면 2·3, TechPRD §5 | ✅ — `CoursonaStudio`(신규 모듈) 의 `PersonaBuildPipeline.run(bundle:template:tier:name:progress:)` 가 `FaceFitter.fit` → `alignments` → `TextureBuilder.build`(faceOnly) → `SplatBinder.build` → `CoursonaPackageStore.write` 를 끝까지 돈다. 합성 번들로 왕복 테스트(`PersonaBuildPipelineTests`, 150번째 테스트) — 디스크에 썼다가 다시 읽어도 등급·스플랫 개수가 그대로 나온다. `CaptureTier` 를 `CoursonaCapture`→`CoursonaCore` 로 옮겨 매니페스트가 등급을 저장할 수 있게 함(반대 방향 의존 문제 해결). `CaptureGuideView` 는 초상 `GuidedCaptureView.swift`(538줄)를 거의 그대로 포팅 — 다른 점: 초상은 iOS(ARKit)·Mac(사진)을 **다른 화면**으로 나눴지만 UXPRD 화면 2 는 "A/B 공용"이라 한 화면에서 `#if os(iOS)` 로 햅틱·ARKit 어댑터만 가르고 본체는 공유, `ShotKind` 7개(선택 2컷 포함)로 칩·아이콘 확장, 완료 시 초상의 "저장+내보내기" 대신 `PersonaBuildPipeline` 을 바로 불러 끝까지 만든다(진행 표시는 최소 버전 — T-807 이 `BuildProgressView` 로 교체). `PhotoSuitabilityView`(화면 3) 는 새로 작성 — `PhotoSuitability` 가 항목별 pass/fail 이 아니라 "적합 여부+실패 이유 목록"만 주므로 그 모양 그대로 보여준다(없는 항목별 체크를 꾸며내지 않음). **실기기 상호작용 테스트(디바이스 인터랙션 서브에이전트)로 재현 크래시 하나 발견·수정**: `PhotoCaptureSession` 에서 카메라 화면 진입 후 뒤로 가기를 반복하면 "stopRunning may not be called between beginConfiguration and commitConfiguration" 로 죽었다 — 원인 둘: ① 세션 설정(`beginConfiguration`~`commitConfiguration`)이 메인 액터에서 동기로, 정지(`stopRunning`)는 백그라운드 큐에서 비동기로 따로 돌아 겹칠 수 있었음(→ 전부 전용 큐 하나로 직렬화), ② (더 결정적) 시뮬레이터처럼 카메라가 없어 `canAddInput`/`canAddOutput` 이 실패하면 옛 코드가 `commitConfiguration()` 을 안 부르고 바로 throw 해서 세션이 "구성 중" 상태로 영영 멈춤(→ `defer` 로 성공·실패 상관없이 항상 짝 맞춤). 수정 후 디바이스 인터랙션으로 반복 재현·확인(5연속 빠른 진입/이탈 + 실제 "시작" 탭 + 실패 배너 경로 전부 크래시 없음) |
| T-807 | UI 3단계: `Views/BuildProgressView.swift`(화면 4, `PersonaBuildStage` 4단계), `Views/InspectionView.swift`(화면 5, T-801 과 통합), `Views/SaveShareView.swift`(화면 6·6b 저장부) | UXPRD §6 화면 4·5·6b | ✅ — `BuildProgressView`: `PersonaBuildPipeline` 의 4단계(피팅·텍스처·입체감·저장)를 체크리스트로 보여준다(완료→진행중→대기 3상태, 텍스처 단계는 세부 진행률 바까지). "얼굴면 완성"은 UXPRD 가 말하는 별도 줄이 아니라 텍스처 단계 문구("눈과 입 주변을 자연스럽게 다듬고…")에 자연히 녹아 있다 — 실제로 캡 닫기가 그 안에서 일어나니까. `CaptureGuideView`/`PhotoSuitabilityView` 가 직접 돌리던 빌드 호출을 이 화면으로 옮겨서 두 화면 다 단순해졌다. `InspectionView`: 초상 `TemplatePreviewView.swift` 의 `RealityView`+`@Observable` 홀더 패턴 재사용, 포즈 세그먼트(무표정·미소·눈 감기·입 벌림·시선)·입체감 토글·"겹침 없음 ✓" 배지(`SelfIntersectionCheck`)·품질 카드(접힘/펼침). `BustEntity` 에 `applySplatRecords(_:)`(이미 구운 스플랫을 다시 바인딩하지 않고 그대로 붙임 — 저장된 페르소나를 다시 열 때용, 갤러리 단계에서도 재사용)와 `hideOutsideFace()`(스플랫·고스트 둘 다 끄는 명시적 메서드) 추가. `RealityViewContent` 는 visionOS 전용이고 iOS·macOS 는 `RealityViewCameraContent` 라는 걸 `DocumentationSearch` 로 확인하고 `some RealityViewContentProtocol` 로 받아 플랫폼 분기 없이 하나로 처리. `SaveShareView`: 이름 입력(20자, 바꾸면 `CoursonaPackageStore.write` 로 재저장)·패키지 요약·`ShareLink` 로 zip 내보내기(6자리 코드 기기 간 전송은 5단계). `RunCodeSnippet` 으로 이 Mac에서 합성 번들 전체 빌드(스플랫 20876개)→zip 내보내기(12MB)→이름 변경 왕복까지 실제로 확인. **2026-10-06부터 아이폰 실기기·시뮬레이터 테스트는 사용자 요청으로 임시 중단** — 이 작업은 Mac 빌드·`swift test`·`RunCodeSnippet`·`RenderPreview`로만 검증했다(iOS/iPadOS 3플랫폼 빌드 확인은 재개 시 다시) |
| T-808 | UI 4단계: `Views/MirrorView.swift`(화면 6, `FaceDriverCoordinator` 연결), `Views/LibraryView.swift`(화면 8, 저장된 `.coursona` 실제 목록) | UXPRD §6 화면 6·8 | ⏳ |
| T-809 | UI 5단계: 초상 `Views/TransferView.swift` 포팅(화면 6b 송수신), 업그레이드 병합 플로우(화면 7b), Mac 3단 워크스페이스(사이드바/뷰포트/인스펙터)·iPad 가로 캡처 분할 | UXPRD §6 화면 6b·7b·Mac-1 | ⏳ |
| T-810 | UI 6단계: 접근성(Dynamic Type·VoiceOver·Reduce Motion), UXPRD §6/§8 bilingual 문구 정확히 맞추기, §11 빈/에러 상태 전부 | UXPRD §9·§10·§11 | ⏳ |

## D · 디자인 — Persona 재현 에셋 (Hair · Shoulders · Eyes/Mouth)

근거: **앱이 받는 것은 `Docs/AssetContract.md`(테크 계약)와 `Template/coursona_assets.json`(매니페스트)이 정본**. 디자인 근거는 디자인 PRD(Claude Doc 「Coursona 디자인 PRD — 비전프로 Persona 재현 에셋」, https://claude.ai/code/artifact/597cc14c-754f-43c5-81d9-c2f29351f464), 계약은 `TemplateValidator.swift`(2차 계약, 2026-10-03). 블렌더 작업 패키지 `coursona_blender/`(스크립트·텍스처·README)를 함께 전달. 원칙: Bust·리그·ARKit 패치는 건드리지 않는다 · 계약 스켈레톤(Root > Spine > Neck > Head > {Eye_L, Eye_R})에 뼈를 더하지 않는다 · 같은 이름 오브젝트를 교체하기 전에 .blend 사본을 저장한다. 아이폰은 스플랫이 없으므로(T-504) Persona 실루엣은 이 절의 메시 에셋이 맡는다. 블렌더 에셋은 모두 색 없는 투명한 틀(무채색 연회색, 불투명도 10%)이며 Bust 피부(Skin) 머티리얼도 같은 값으로 둔다(`skin_carrier`, 머티리얼 값만 — 메시·리그·그룹·UV·셰이프키 불변). 색과 윤곽은 앱이 트루뎁스 정점으로 코드에서 만들므로 미리보기 두상은 둥근 타원체 하나(이마·턱·코·입술 볼륨 없음)이고 남녀 차이는 머리폭·목 둘레·어깨폭뿐이다.

### D0 · 준비

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| D-001 | 계약 확정: coursona 포팅 검증기와 초상판(2차 계약)의 차이, export_coursona.py 위치·CLI 인자, library.json 최상위 형태 | PRD §에셋 계약, Q-D2·Q-D3 | 🔄 — 초상판 `TemplateValidator.swift` 확인: 이름 규칙 `^(Hair\|Glasses\|Beard\|Shoulders)_[a-z0-9_]+$`, `hairStyles` 에 long_wave, `requiredLibrary` 에 Shoulders_shirt(**두 오브젝트는 초상 .blend 에 이미 있을 가능성 높음 → 교체**), 스켈레톤 6뼈(**Mouth_Inner 뼈 없음 → Head 강체**), 눈 뼈 머리 = 눈알 중심 0.5 mm, `mouthInnerShapes` 5개, `--no-usdz` 금지. coursona 포팅본·CLI 인자는 미확인 |
| D-002 | `coursona_blender/` 를 맥(예: `~/Desktop/coursona_blender`)에 두고, 블렌더 쪽 Claude 에게 README 의 요청문으로 `run_all.main(export=False)` 실행 요청 | PRD §제작 파이프라인 | ✅ — **2026-10-07 밤, 앱 쪽 Claude 가 헤드리스로 직접 실행**(블렌더 쪽 Claude 불필요): `/Applications/Blender.app`(5.2.2, numpy·pxr 내장) + 초상 `Chosang_Template.blend` 사본을 리포 안 `.blender_work/`(gitignore)에 두고 `Blender -b Coursona_Template.blend --python run_blender.py`. **함정 둘**: ① 샌드박스가 `~/Desktop`·`~/.thumbnails` 쓰기를 영원히 막아 첫 실행이 `save_mainfile` 의 썸네일 `fopen` 에서 멈췄다 → 러너에서 `preferences.filepaths.file_preview_type = 'NONE'`, 작업 폴더는 리포 안 ② 블렌더 쪽 Claude 의 `export_coursona.py` 는 존재하지 않는다 — 실제 스크립트는 초상 리포 `Chosang/tools/blender/export_chosang.py`(읽기 전용, `--out` 필수) |

### D1 · 블렌더 에셋 (블렌더 쪽 Claude)

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| D-101 | 진단 `fix_eyes_mouth.diagnose()`: Eye_L/R·Mouth_Inner 의 존재·스킨(단일 뼈 100% 여부)·머티리얼·셰이프키·컬렉션, Hair_long_wave·Shoulders_shirt 기존 여부를 보고서에 기록 | PRD §에셋 스펙 3 | ⏳ |
| D-102 | Shoulders_shirt: Shoulders 영역 셸 3.5 mm + 칼라(스탠드 앞 18·뒤 24 mm, 리프 뒤 30·앞 포인트 60 mm) + 절단면 안쪽 접기, Root·Neck 가중치 복사·정규화, `M_Shirt_Navy`(#1E2A44, roughness 0.82), UV v = 높이 | PRD §에셋 스펙 2 | 🔄 — `add_shoulders_shirt.py` 작성. 대리 흉상에서 칼라 최소 간격 3.7 mm·앞 포인트 확인(첫 시도의 광선 방식 리프가 망토처럼 퍼져 표면 걷기로 수정). **v1.2**: `sex` 프리셋(남성: 스탠드 20/26 mm·리프 32 mm·단추 6 mm). **v1.3**: 머티리얼 무채색 10%. **v1.1 디테일**: 앞 플래킷(1.6 mm 덧단) + 단추 4개(8.5 cm 간격, 슬롯 `M_Shirt_Button`) + 칼라 단추, 옷 주름 ±0.7 mm, 등 요크 솔기. 블렌더 미실행 |
| D-103 | Hair_long_wave(셔츠 **다음**): 두피 캡 + 카드 284장 3층, 가운데 가르마, 볼 높이부터 웨이브(파장 9.5 cm, 진폭 11 mm), 아래 표면(어깨·등·칼라) 1.8 cm 위에서 끝, Head 강체, `T_Hair_LongWave_base.png`(2048², 회색+알파, 평균 회색 0.64) | PRD §에셋 스펙 1 | 🔄 — 스크립트·텍스처 완료, 대리 흉상 렌더로 형태·간격 확인. **v1.1 디테일**: 층 5개(inner·mid·outer + 얼굴 감싸는 frame 12장 + 헤어라인 잔머리 baby 70장, 총 366장·약 2.3만 정점), 카드 비틀림·폭 변화, 가르마 +5 mm 오프셋, 텍스처에 발레아주·하이라이트 가닥·잔머리 + `T_Hair_LongWave_mask.png`(R 뿌리→끝, G 가닥 id, B 하이라이트). 블렌더 미실행 |
| D-104 | Eye_L/R·Mouth_Inner: 단일 뼈 스킨 → 강체 전환, 눈 오리진 = 눈 뼈 머리(0.5 mm), 슬롯 공막→홍채→동공(기하 판정 재정렬), Mouth_Inner 는 Head 강체 + 셰이프키 5개(Bust 의 같은 키에서 턱끝 Kabsch 맞춤) + 드라이버. 없을 때만 생성 | PRD §에셋 스펙 3 | 🔄 — `fix_eyes_mouth.py` 작성, 생성기·Kabsch 오프라인 검증(회전 18.00° 복원). **v1.2**: 전부 삼각형·고밀도(눈 2,498정점·4,992면, 생성형 입안 7,640정점·14,072면), 홍채 접시(0.5 mm, 눈꺼풀 안전), 절치 유두·대구치 교두·중심와, 둥근 잇몸 단면, 설유두 요철, `sex` 프리셋(남성 기본). **v1.3**: 입 돌출 조절 `mouth_protrusion`(m, 앞니 1 mm당 2° 순측 기울기)·`overjet`·`overbite` 파라미터, 머티리얼 무채색 10%, 폴백 텍스처는 `coursona_textures` 속성으로만 참조. **v1.1 디테일**: 홍채·공막 텍스처(`T_Eye_Iris_base.png` 섬유·크립트·림벌 링, `T_Eye_Sclera_base.png` 혈관) + 눈 UV 재작성(홍채 평면·공막 구면), 치아 해부 형태(삽 모양 절치·송곳니 첨두·대구치, ±2° 어긋남)와 `T_Teeth_base.png`, 치은 스캘럽, 혀 정중 고랑. 블렌더 미실행 |
| D-105 | `run_all` 보고서(`Template/coursona_build_report.json`) 전 항목 pass + 뷰포트 정면·¾·측면을 레퍼런스 이미지와 나란히 비교 | PRD §검수 | 🔄 — **실제 Bust 에서 1차 실행 결과(2026-10-07)**: Shoulders_shirt **pass**(몸판 최소 2.1 mm·칼라 3.7 mm, 포즈 7종 관통 0, 5,205 정점·10,084 삼각형). Hair_long_wave **fail**: 캡 pass(1.49 mm), 카드 레스트 1점 1.07 mm(<1.4), **포즈 7종에서 카드가 어깨·목을 관통**(yaw 30° 248점/−18 mm, pitch_up20 2,321점/−30 mm) + 레스트 Bust 삼각형 교차 240 — 강체 Head 부착 + 36 cm 긴 머리의 구조적 한계(PRD "결정 — 머리 길이"의 예상대로; 앱은 흉상 전체가 한 덩어리로 돌아 실제 관통은 안 보임). hair_vs_shirt 같은 이유로 fail. Eye_L/R **fail 은 검사 정의 문제**: `lid_gap_min_mm` 가 전 키에서 정확히 −1.5 — 초상 LidInner 2열이 눈알 반지름 −1.5 mm 구면 위에 있도록 **설계**된 값이라 "눈꺼풀 ≥ 0.2 mm 바깥" 기준과 상충. Mouth_Inner fail(`teeth_vs_lips` 전 키 ≈ −6.0 mm 상수, inside 51–1,164) 도 같은 종류로 의심(입 캡 포켓 6 mm 와 일치) — 앱에서 입 벌림 포즈 때 윗니·입안이 입술 안쪽에 정상 표시됨. 레퍼런스 나란히 비교는 미실시 |
| D-106 | 테크 데이터: 모든 에셋 삼각화((a,b,c)+(a,c,d)), uv1 `CoursonaData` = (presence, height01), 면 구간(`faceRanges`), `topologyHash`, 매니페스트 `coursona_assets.json` | `Docs/AssetContract.md` §4·§5 | 🔄 — 스크립트 완료(오프라인 검증), 블렌더 미실행 |
| D-107 | 머리 스플랫 호스트: 볼륨 셸 3겹(삼각형, 고유 UV, 가닥 방향 flow) → `hosts/SplatHost_Hair_long_wave.json`, 블렌더 원본은 내보내기 제외 컬렉션 `Splat_Hosts` | `Docs/AssetContract.md` §6 | 🔄 — 스크립트 완료(대리 흉상 검증), 블렌더 미실행 |

### D2 · 내보내기·검증

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| D-201 | T-003 가드 해제: `mouthInnerShapes` 메타와 Template.usdz 안의 Eye_L/R·Mouth_Inner 실메시를 로드(EyesMouth.usdz 는 계속 미사용) | PRD §리스크, T-003 | ✅ — 앱은 `coursona_assets.json` 경로로 Template.usdz 의 Eye_L/R(강체 Xform, 2,498 정점)·Mouth_Inner(블렌드셰이프 5, USD 가 만든 더미 Skel 포함)를 직접 붙인다(InspectionView → `attachPersonaAssets`). `mouthInnerShapes` 는 template.json 에 그대로 나가고 검증기만 본다. EyesMouth.usdz 는 매니페스트 없는 옛 템플릿용 폴백으로만 번들에 남김 |
| D-202 | export_coursona.py 를 CLI 로 실행(`--no-usdz` 없이, Apply Modifiers OFF) → Template.usdz·textures·library.json | PRD §제작 파이프라인 | ✅ — `Blender -b Coursona_Template.blend --python pre_export.py --python Chosang/tools/blender/export_chosang.py -- --out <Template>`. **`pre_export.py` 가 필요했다**: 초상 .blend 의 Library_Hair 컬렉션이 뷰 레이어에서 제외돼 있어 `select_set` 이 실패, 머리 12종의 `library/*.usdz` 가 아마추어만 든 4 KB 로 나왔다(초상 Template/library 가 비어 있던 이유). 전부 포함시킨 뒤 19종 정상(67 MB). bust.mesh 는 기존과 바이트 동일, template.json 은 `textures`·`libraryObjects` 순서만 다름 |
| D-203 | `inspect_usdz.py` problems 0: 다섯 이름이 프림, 강체 3종(Hair·Eye·Mouth)에 조인트 가중치 없음, 셔츠 조인트 Root·Neck, Mouth_Inner 블렌드셰이프 5. 실패하면 `attach_mode="CHILD_OF"` 로 D-103·D-104 재실행 | PRD §리스크 | 🔄 — pxr 검사: Hair_long_wave 는 `library/Hair_long_wave.usdz` 에 SkelRoot 밖 Xform(스킨 없음) ✓, Eye_L/R 은 Template.usdz 의 SkelRoot 아래 Xform 이지만 RealityKit `findEntity` 로 잡힘 ✓(CHILD_OF 불필요), Mouth_Inner 는 블렌드셰이프 때문에 USD 가 `Mouth_Inner/Skel`(joint1) 바인딩을 붙임(예상된 구조, 앱 `BlendShapeWeightsComponent` 로 jawOpen 구동 확인), Shoulders_shirt 는 스킨 ✓ 이나 inspect 가 조인트 목록을 못 읽음(메시가 아니라 Skel 에 있음 — 검사 쪽 거짓 음성). **앱 쪽 발견**: 스킨 메시는 RealityKit 이 Armature 엔티티 하나로 합쳐 프림 이름 아래 ModelComponent 가 없다 → `PersonaAssets.libraryModelEntity` 폴백 추가(라이브러리 usdz 의 유일한 모델) |
| D-204 | `tools/make_default_template.sh` 로 Default.coursonatemplate 재생성 → `coursona-validate` 오류 0 | PRD §검수 | ✅ — `coursona-validate <Template> --with-usdz` 오류 0(경고는 previz.missing 11개뿐 — 프리비즈 mp4 는 복사 제외). 스크립트 갱신: `coursona_assets.json`·보고서·`hosts/`·매니페스트가 가리키는 `library/<prim>.usdz` 만(19종 전부 넣으면 +67 MB) 포함, 기본 출력 경로 오타(`coursona/coursona/…`) 수정. 번들 31 → 45.8 MB |

### D3 · 앱 룩 (앱 쪽 Claude)

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| D-301 | RigidAttach 시스템: library.json `bone`(Head·Eye_L·Eye_R)의 조인트 변환을 매 프레임 강체 에셋 엔티티에 복사 — 클립·라이브 고개 회전을 따라가게. **없으면 강체 에셋 3종이 고개를 안 따라감** | PRD §리스크 | 🔄 — `PersonaAssets.swift` `BustEntity.attachPersonaAssets`: 눈 프림은 `identity.eyeCenterL/R` 피벗 아래로, 입안·헤어는 Head(=`model`) 아래로 재부모화해 기존 `applyHeadPose`/시선 회전을 그대로 따라감(별도 매 프레임 복사 불필요). 실에셋 검증 ✓(D-401, 2026-10-08) |
| D-302 | 아이폰: 라이브러리 헤어·셔츠 착용 시 Bust 나머지 파트 opacity 1.0(현재 기본 0, T-103·Q2) — 목·귀가 비어 보이지 않게 | PRD §룩·렌더링 | ✅ — 입체감 v3(`832b8b9`)가 머리~어깨를 단일 메시·단일 머티리얼(불투명)로 그려 이미 충족 |
| D-303 | 헤어 머티리얼: 에셋은 opacity 0으로 오므로 앱이 실루엣 알파를 opacity 텍스처로 연결 후 `opacityThreshold` 0.45, `faceCulling = .none`, 틴트 = 목표색 ÷ 0.63, 사진 머리색·선택 유지(T-704) 연결 | PRD §룩·렌더링 | 🔄 — `PersonaAssets.material(role: .hair …)`: `PersonaTextureCache.alphaMask` → opacity, threshold 0.45, culling none, 틴트 = `PersonaLook.hairTint ÷ hairTextureMeanGray(0.63)`; InspectionView 가 `manifest.hairTint`(사진 머리색) 를 넘김. 실에셋 검증 ✓(D-401, 2026-10-08) |
| D-304 | 셔츠 하단 페이드: UV v 0 → 0.35 알파 그라데이션(CustomMaterial 표면 셰이더) | PRD §룩·렌더링 | 🔄 — `PersonaSurface.metal`(`coursonaPersonaSurface`) smoothstep(fade.x, fade.y, uv1.y); `PersonaLook.shirtFadeHeight01` 기본 (0, 0.18). uv1 베이크는 macOS/iOS 27+ (`textureCoordinates1`), 그 아래는 PBR 폴백 |
| D-305 | 눈: 실제 눈알이 있으면 시선 = 엔티티 회전(eyeLook 8방향), 캡 UV 이동(T-604)은 눈알 없는 템플릿 폴백. 공막 0.18 · 홍채 0.25 + clearcoat 0.6 · 동공 0.10 | PRD §룩·렌더링 | 🔄 — 눈 프림을 `eyePivotL/R` 로 재부모화(기존 시선 회전 경로 재사용), 캡은 `setCapsHidden`; role 별 roughness 공막 0.18·홍채 0.25(clearcoat 0.6)·동공 0.10. 실에셋 검증 ✓(D-401, 2026-10-08) |
| D-306 | 입: Mouth_Inner `BlendShapeWeightsComponent` 에 Bust 와 같은 5개 가중치(FaceRigSystem 합성 결과를 그대로) | PRD §에셋 스펙 3 | 🔄 — `mouthInner` 설정 → 기존 `updateMouthInner` 가 가중치 복사. 실에셋 검증 ✓(D-401, 2026-10-08) |
| D-307 | Mac 스플랫 정리: 헤어 착용 시 두피 스플랫, 셔츠 착용 시 어깨 스플랫 끄기(T-503) | PRD §룩·렌더링 | ⛔ — 스플랫(CoursonaSplat)이 `832b8b9` 에서 영구 제거됨. 끌 스플랫이 없어 해당 없음 |
| D-308 | **유령 룩 합성**: 블렌더 에셋은 색을 뺀 투명한 틀(무채색 연회색, 기본 opacity 0.10 = 90% 투명, `coursona_opacity`·`coursona_colorless`)로 받고, 앱이 ① 사진 기반 색 입히기(머리 틴트·셔츠 평균색·눈/입 투영, 없으면 블렌더 폴백 텍스처) ② 머리 실루엣 = `textures.base` 알파(`coursona_silhouette`) ③ 페르소나만 오프스크린 렌더 → 가장자리 8–14 px 블러 → 전체 불투명도 0.85 → 하단 페이드 → 배경 위 합성. 레퍼런스처럼 반투명·흐린 경계 | PRD §룩·렌더링 원칙 | 🔄 — ①② 는 D-303/309 로 구현(틴트·셔츠색·홍채색·실루엣 알파). ③ 은 **흉상 자체 셰이더로 1차 근사**(2026-10-07 밤): `coursonaPersonaBust`(`PersonaSurface.metal`) + `BustEntity.setGhostLook` — 프레넬 가장자리 소멸 0.6 + 모델 y 하단 8 cm 페이드, 검사 화면 "유령 룩" 토글(기본 켬). 기본 불투명도는 **1** 로 둔다 — 검은 무대에서 0.85 는 반투명이 아니라 15% 어둡게 보일 뿐이고 반투명 입술 뒤로 입 캡이 비쳤다(실측). 밝은 배경을 도입할 때 0.85 + 오프스크린 가장자리 블러를 다시 검토. **실측 함정**: 초기 피부 PBR 의 살구색 틴트(0.86,0.68,0.58)가 텍스처를 올린 뒤에도 남아 `base_color_tint()` 로 셰이더에 들어와 색이 어둡고 주황으로 변했다 → 흉상 셰이더는 틴트를 곱하지 않고 `setSkinTexture` 가 틴트를 흰색으로 명시. 켬/끔 픽셀 차 이마 (248,223,201) vs (252,230,213) 로 일치 확인 |
| D-309 | 에셋 로더: `coursona_assets.json` 단일 진입점 — 스키마 확인, 프림 이름으로 엔티티 찾기, 삼각형 수·`topologyHash` 확인(정점 수는 UV 솔기 분할로 달라질 수 있음), 머티리얼 슬롯을 역할(role)로 매핑 | AssetContract §4·§8 | 🔄 — `CoursonaCore/Models/AssetManifest.swift` + `TemplateStore.loadAssetManifest/templateUSDZURL/texturesFolder`, `AssetManifestTests`(스키마·presence 식·관대한 library.json). 실제 산출물로 검증 ✓(D-501) |
| D-310 | presence 셰이더: CustomMaterial 표면 셰이더에서 uv1.x(없으면 §5 식) × 기본 불투명도, 프레넬 가장자리 사라짐 `pow(1−|N·V|, 2)` — 블렌더 데이터 + 코드 식 둘 다 지원 | AssetContract §5 | 🔄 — `coursona/Shaders/PersonaSurface.metal` + `PersonaSurfaceShader.swift`(default.metallib 에 포함 확인). uv1 이 없으면 `PresenceParams.presence(at:headJoint:)` 로 앱이 베이크(`bakePresenceUV1`) |
| D-311 | (macOS) 스플랫 바인딩 확장: `SplatBinder` 가 호스트 JSON(머리 셸)과 셔츠 body·collar 구간을 받아 바인딩 — 장축 = flow, 겹 0·1 볼륨/겹 2 잔머리, 사진 투영으로 초기 색. 스플랫이 켜지면 틀 메시는 `OcclusionMaterial` | AssetContract §6·§7, T-503 | ⛔ — CoursonaSplat 모듈 제거로 보류. 블렌더 쪽 D-107 호스트 산출물은 만들어 두되 앱은 소비하지 않음 |

### D4 · 검수

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| D-401 | 레퍼런스 비교 렌더(정면·¾) + T-802 스냅샷 세트에 Persona 룩(헤어·셔츠 착용) 추가 | PRD §검수 | 🔄 — **실에셋 앱 검수 1차(2026-10-08 00:00, Mac)**: 매니페스트 5/5 부착, 삼각형 수 전부 일치(헤어 33,656·셔츠 10,084·눈 4,992×2·입 14,048), 셰이더 O. 5° 몽타주(`/tmp/sweep3/montage.png`)·포즈 5종(`/tmp/poses.png`): 머리(사진 틴트 0.21 회색)·네이비 칼라 셔츠·단추·하단 페이드·입 벌림 때 윗니/입안 ✓. **발견·수정 셋**: ① 3/4 뷰에서 먼 쪽 볼이 검게 뚫림 — 헤어 카드가 opacity 0 으로만 가리면 카드 사각형 전체가 깊이를 써 뒤의 반투명 흉상이 지워졌다 → 셰이더에서 알파 ≤ 0.45 는 `discard_fragment()` ② presence(정면 외 사라짐) 가 턴테이블에서 먼 쪽 머리·셔츠를 지워 속이 비어 보임 → `PersonaLook.presenceEnabled` 추가, 검수 화면은 끔 ③ 셔츠 페이드 아래로 흉상 피부 띠 → 흉상 유령 페이드 14 cm. **3차(2026-10-08, 트루뎁스 A등급 실기기 — 가정 진단)**: 사용자가 iPhone 실기기(TrueDepth)로 직접 만든 페르소나에서
"두 가지 버전이 겹친 상태 같다"고 보고. Device Interaction 이 이 환경에서 실기기를 지원하지 않아(시뮬레이터만
가능) 화면을 직접 보지 못해, 사용자 요청대로 코드 추적으로 원인을 가정·확인했다. **원인**: `PersonaAssets.swift` 의
`attachPersonaAssets` 에서 Eye_L/R·Mouth_Inner 는 각자 스케일 보정이 있었다(`eyeScale`, `max(0.6,min(1.6,identity.scale))`)
— 하지만 헤어·셔츠(`default:` 분기)는 `restCenter: .zero` 로 블렌더 레스트 위치에 **보정 없이** 그대로 붙어 있었다.
B·C 등급(사진)은 `identity.scale` 이 항상 1(단안 사진은 절대 크기를 모른다, TechPRD §6.3)이라 이 빠진 보정이 지금까지의
모든 Mac 테스트에서 전혀 드러나지 않았다 — A 등급(TrueDepth)만 F1/F3 에서 실제 깊이로 전역 유사변환 스케일 s 를 구하므로,
사용자의 실제 머리가 블렌더 대리 흉상과 몇 % 라도 다르면 헤어·셔츠가 실제 크기로 피팅된 흉상과 어긋나 두 레이어가 겹쳐
보인다. **수정**: 헤어·셔츠를 `headJointRest` 를 축으로 `clamp(identity.scale, 0.6, 1.6)` 만큼 균일 스케일하는 피벗을
추가(`scalePivots`, kind별 1개 공유). 이방성(모양) 차이까지는 안 고친다 — 그건 부위별 워프가 필요해 범위 밖. 140/140
테스트·Mac 빌드 통과, scale=1 인 기존 Mac 페르소나는 4각도 렌더가 수정 전과 동일(회귀 없음, 실측 비교). **사용자가
보낸 수정 전 실기기 스크린샷 5장(0°·45°·90°·−45°·−90°, README "실기기(iPhone, TrueDepth A등급) 첫 촬영" 절·
`Docs/screenshots/d4-persona-iphone-truedepth-sweep.png`)으로 가설이 실측으로 확인됐다** — 양쪽 어깨·칼라 경계가
피부색·남색 톱니 패턴으로 번갈아 보이는 것이 정확히 "셔츠 메시 가장자리 ≠ 실제 어깨 윤곽" 증상이다. **수정이 적용된
빌드로는 아직 재촬영 못함** — `coursona-iphone-truedepth-plan.md` 의 실기기 패키지 교환 절차로 다음에 확인.

**2차(2026-10-08 00:40) — 남았던 넷 처리**: ① 눈 감기: 눈알은 정확한 12 mm 구(USDZ 실측, 처음 "찌그러졌다"고 본 건 홍채 쪽 정점 밀도로 치우친 무게중심을 기준으로 잰 내 실수)였고, 진짜 원인은 **사진 피팅의 눈 둘레 RBF 워프와 눈꺼풀 닫힘 궤적의 어긋남** — 앱 안 실측 eyeBlink 1.0 에서 눈꺼풀 패치 128점 중 49점이 구면 안(최소 −2.7/−4.1 mm). `BustEntity.eyeDepthCorrection`: 눈을 감은 눈꺼풀 정점이 모두 구면 +0.5 mm 바깥에 올 때까지 눈 중심을 뒤로(최대 6 mm, 실측 L 3.5·R 5.0 mm) → 눈 감기에서 눈꺼풀이 닫히고 뜬 눈의 "튀어나온 눈" 인상도 사라짐(`d4-persona-eye-closure.png`). `coursona-validate --fit` 에 눈 감기 점검(구면 거리·눈 구멍 테두리 세로 폭 뜸 10.9 → 감음 3.1 mm) 추가 ② 두피 캡: `faceRanges.cap` 삼각형을 별도 파트로 떼어(`splitTriangleRanges`) 카드 틴트 ×0.78 머티리얼 — 밝은 회색 판은 사라졌으나 정수리에 어두운 면이 남음(캡 칸 텍스처 자체 개선 필요) ③ 레퍼런스 나란히 비교 `d4-persona-reference-compare.png`(README 에 수록) ④ 헤어 v2: `max_len 0.28·tip_clear 0.035·max_lateral 0.115` 로 재생성·재내보내기 — 포즈 관통 yaw 248→60점, pitch_up 2,321→634점(4배 감소, 0 은 아님), 레스트 Bust 교차 240→273. 번들 재생성(45.9 MB) |
| D-402 | 🧪 실기기: 아이폰 거울 화면 60 fps(헤어 알파 오버드로), 고개 좌우 30°·숙임 25°에서 관통 없음, jawOpen 1.0 에서 아래 치아·혀가 입술과 함께 내려감 | PRD §검수 | ⏳ |

### D5 · 다음 작업 대비 (2026-10-07 밤, 디자인 PRD·UXPRD 대조)

블렌더 산출물(Template.usdz·textures·library.json·coursona_assets.json)이 도착하면 아래 순서로 받는다. 앱 쪽 코드는 전부 들어가 있고 실에셋으로만 미검증이다.

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| D-501 | 수신 즉시: `coursona-validate` 로 Template 폴더 검사(오류 0) → `Docs/AssetContract.md` §8 로드 검사 항목(스키마 `coursona-assets/1`, 프림 5개 존재, 삼각형 수·`topologyHash`, 강체 3종 조인트 가중치 없음, 셔츠 Root·Neck, Mouth_Inner 셰이프 5) 을 `AssetManifestTests` 픽스처 대신 실제 파일로 한 번 더 | AssetContract §8, D-203 | ✅ — D-203/D-204 참고. 산출물 원본은 `.blender_work/Template/`(gitignore), 보고서는 번들 안 `coursona_build_report.json` |
| D-502 | `tools/make_default_template.sh` 로 Default.coursonatemplate 재생성 → Mac 앱 검사 화면에서 `attachPersonaAssets` 보고서(`PersonaAssetReport.notes`) 확인: 헤어·셔츠·눈·입 부착 수, uv1 베이크 여부(OS 27), 폴백 사유 | D-204, D-301~310 | ✅ — 5/5 부착·셰이더 O(D-401 참고). `PersonaBuildPipeline` 이 `manifest.hairTint` 를 사진 머리색으로 채우도록 추가, 옛 패키지는 `BustEntity.estimateHairColor`(두피 텍셀 평균)로 폴백 |
| D-503 | 룩 검수: 회전 슬라이더 5° 몽타주(`/tmp/coursona_tools/sweep2.sh` 방식)로 −90…90° 헤어 실루엣·칼라 관통·눈알 피벗·입안 jawOpen 확인, 레퍼런스(`Apple-WWDC25-visionOS-26-Personas`)와 정면·¾ 나란히 비교. 헤어 틴트 = `manifest.hairTint ÷ 0.63`, 셔츠 하단 페이드 (0, 0.18) 수치 조정 | D-401, UXPRD §3 원칙 1 | 🔄 — 몽타주·포즈 촬영 완료(D-401). 남은 것: 눈 감기 때 눈알 돌출, 두피 캡 밝기, 레퍼런스 나란히 비교, 헤어 생성 파라미터(`tip_clear`·길이)로 D-105 포즈 관통 줄이기 |
| D-504 | 유령 룩 2차: 무대 배경을 UXPRD Liquid Stage(#0B0D12~#14171F 그라데이션)로 바꾼 뒤 기본 불투명도 0.85·오프스크린 가장자리 블러(8–14 px) 재검토. 투명 패스에서 입 캡·뒤통수가 비치는 문제는 캡을 `setCapsHidden` 로 숨기거나 흉상을 두 패스(불투명 깊이 → 반투명 색)로 | D-308 ③ | ⏳ |
| D-505 | 기존 품질 이슈(에셋과 무관, 두 코르소나 공통): ① 얼굴/두피 텍스처 경계 계단(얼굴 밖 관측 버림 2.9–3.4만 텍셀) — 헤어 에셋이 가리면 우선순위 하락 ② 반대쪽 볼 채움 톤이 관측 볼보다 밝음(`TextureFill` 피부 기준색 vs 관측 음영) ③ 눈알 공막 과백·돌출(D-104 실에셋 대기) | 2026-10-07 각도 몽타주 | ⏳ |
| D-506 | UXPRD 화면 5(검수) 미구현 요소: 상단 좌 "다시 촬영", 액션 바 "거울로 보기"(T-808 MirrorView 필요), 풀업 품질 카드 4칸 그리드(관측 비율/빌드 소요/자기교차/표면 정밀도), 경고 상태 "겹침 N곳 — 다시 촬영 권장"(현재 "겹침 의심 227곳" 은 캡 뒤집힘 근사치라 문구·기준 재정의 필요). "회전" 슬라이더·"유령 룩" 토글은 UXPRD 에 없는 점검용 — 출시 전 "자세히" 아래로 이동 | UXPRD §6 화면 5, T-801 | ⏳ |
| D-507 | UXPRD 플랫폼 구조: Mac 3단(사이드바·뷰포트·인스펙터 품질/환경 설정 탭 — 조명 보정·머리카락 틴트·배경 분리 민감도), iPad 가로 캡처 분할 — 머리카락 틴트 슬라이더는 `PersonaLook.hairTint` 에 바로 연결 가능 | UXPRD §4·Mac-1, T-809 | ⏳ |

### 디자인 미결 사항

| # | 질문 | 현재 기본값 | 이 태스크에 미친 영향 |
|---|---|---|---|
| Q-D1 | 초상 헤어 11종(Head 100% 스킨)을 강체로 일괄 전환할지 | 이번엔 Hair_long_wave 만 강체 | D-103·D-301 |
| Q-D2 | library.json 최상위 형태(배열 / `{items}`) | 기존 형태 유지, 없으면 배열로 생성 | D-001 |
| Q-D3 | export_coursona.py 위치·CLI 인자, coursona 검증기 포팅 차이 | 초상판 2차 계약 기준 | D-001·D-202 |
| Q-D4 | v2 어깨를 덮는 앞머리: Neck 스킨 vs 2차 모션 | v1 은 어깨 위 1.8 cm 에서 끝 | D-103 |
| Q-D5 | 유령 룩 합성 방식: RealityKit 포스트프로세스(renderCallbacks) vs 오프스크린 2패스 | 2패스(실루엣 마스크 블러) | D-308 |
| Q-D6 | RealityKit 이 USD 의 두 번째 UV(uv1)를 MeshResource 로 넘기는지 | 미확인 — 안 넘기면 presence 는 §5 식으로 계산(D-310) | D-106·D-310 |

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
8. Persona 룩(D 절): 라이브러리 헤어·셔츠 착용 상태로 고개 좌우 30°·숙임 25° 관통 없음, 입 벌림에서 치아·혀 동행, 아이폰 60 fps.
