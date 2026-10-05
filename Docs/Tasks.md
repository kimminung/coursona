# 코르소나 (Coursona) — Tasks

상태: ✅ 완료 · 🔄 진행 · ⏳ 대기 · 🧪 실기기 검증 필요 · 🔬 스파이크(결과에 따라 설계 분기)

원칙(초상 계승): 마일스톤 끝에 4개 빌드(iOS 시뮬·iPadOS 시뮬·macOS·iPhone/Mac 실기기) 통과 + 체크리스트. 근거 문서는 `Docs/TechPRD.md` v0.2(절 번호는 거기 기준), UI 근거는 `Docs/UXPRD.md`. 모든 항목은 2026-10-05 현재 ⏳(미시작) — **구현 착수는 별도 지시 이후**.

## C0 · 프로젝트 셋업

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-001 | Xcode 프로젝트 `Coursona`: iOS·iPadOS·macOS 한 타깃(family 1,2 + Mac), 번들 `com.coulson.Coursona`, 배포 iOS 26·iPadOS 26·macOS 26, 엔타이틀먼트(카메라·마이크·로컬 네트워크·사진 보기) | §3, §8 | ⏳ |
| T-002 | 로컬 Swift Package `CoursonaKit` — 초상 `ChosangKit` 소스를 **파일 단위로 복사**해 모듈 리네임: Core·Capture·Fit·Face(신규)·Texture·Splat(신규)·Rig·Drive(신규)·IO·ML(신규), 테스트 타깃 포함. 초상 리포를 경로로 참조하지 않는다 | §6.1 | ⏳ |
| T-003 | 템플릿 반입: `Default.chosangtemplate`(template.json·bust.mesh·Template.usdz·textures·clips)만 복사. `EyesMouth.usdz`·`mouthInnerShapes` 메타는 **쓰지 않는다**(참조하지 않도록 로더에서 가드) | §6.2 | ⏳ |
| T-004 | 초상에서 포팅한 테스트 스위트 전체(`FitTests`·`SelfFitTests`·`TextureBuilderTests`·`TextureRegionsTests`·`SparseCaptureTests`·`CaptureGuideTests` 등)를 기준선으로 `swift test` 녹색 확인 | §9 | ⏳ |
| T-005 | `TierClassifier`: `ARFaceTrackingConfiguration.isSupported` + 2초 내 `capturedDepthData` 수신 → A, 실패 시 B(iOS/macOS 공통), 사용자가 "사진 1장"을 고르면 C. 세 진입점을 **막지 않는다** | §3, §5 | ⏳ |
| T-006 | 4개 빌드(iOS 시뮬·iPadOS 시뮬·macOS·실기기 1종) 통과 | — | ⏳ |

## C1 · 한 메시·투명 흉상

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-101 | `FaceSurfacePartition`: 얼굴면(ARKitFace∪LidInner∪LipInner) 삼각형과 나머지를 분리해 `LowLevelMesh.Part` 구성. 인덱스 재배열 결과를 1회 캐시 | §6.2 | ⏳ |
| T-102 | `CapBuilder` v0(템플릿 좌표 기준): 눈 캡(49정점·72삼각형×2) · 입 캡(73정점·108삼각형) 생성 — 블렌더 `eye_band`/`mouth_band` 상수 재현 | §6.2, §6.4 F5/F6 | ⏳ |
| T-103 | `BustEntity` 파트 렌더: 기본은 얼굴면(패치+띠+캡)만 불투명 머티리얼, 나머지는 파트 **제외**. 디버그 고스트 토글(opacity 0.15) | §6.2, §3 | ⏳ |
| T-104 | 단위 테스트: 캡 템플릿 자기 일치 0.0mm, 워터타이트(경계 모서리 0) 검사 | §9 | ⏳ |

## C2 · 얼굴면 완성 (A 등급 밀집 경로)

| ID | 작업 | 근거(F-단계) | 상태 |
|---|---|---|---|
| T-201 | `EyeOpeningSolver`(F2): 눈 루프 사전값 + 눈 감기 컷 4변수 최소제곱 | F2 | ⏳ |
| T-202 | `SilhouetteFitter` 제외 영역 수정(F4): 눈·입 루프 2-링, 루프 투영 안 깊이점 제외 | F4 | ⏳ |
| T-203 | `InnerBandBuilder`(F5): LidInner 96·LipInner 72 재생성, s 배, 인덱스↔루프 순서 추론·캐시(`InnerBandIndexMap`, 0.5mm 임계) | F5 | ⏳ |
| T-204 | `CapBuilder` v1(F6): 피팅값(눈알 중심·반지름, 입 루프 평균) 반영해 캡 재생성, `caps.json` 출력 | F6 | ⏳ |
| T-205 | `UserShapeDeltas`(F7): 눈 감기·입 벌림 컷이 있으면 `eyeBlink_L/R`·`jawOpen` 패치 델타 치환 | F7 | ⏳ |
| T-206 | `RegionDeltaBuilder`(F8): 띠·캡의 셰이프 델타를 피팅된 눈알 중심 기준으로 재계산 | F8 | ⏳ |
| T-207 | `SelfIntersectionCheck`(F9): 4종 검사(눈 띠↔캡, 입 캡↔띠, 윗입술↔아랫입술, 위↔아래 눈꺼풀), 위반 시 띠 상수 0.5mm씩 최대 3회 재시도 | F9 | ⏳ |
| T-208 | `Identity` → identity.bin **v3**(regionDeltas·caps), v1·v2 읽기 호환 유지 | §6.7 | ⏳ |
| T-209 | `coursona-validate --fit`: 돌출 대신 **자기교차 지표**(개수·최대 깊이) 출력 | §6.9 | ⏳ |
| T-210 | 🧪 합성 번들 자기교차 0, 실기기 A 번들(iPhone) 자기교차 0 | §9 | ⏳ |

## C3 · 캡처 A/B/C

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-301 | `FaceCaptureSession` 7컷(필수 5+선택 2), `AVDepthData.cameraCalibrationData` 저장, 저장 시 5/5 깊이 검증 | §6.3 A | ⏳ |
| T-302 | `PhotoCaptureSession` 확장: B 등급 5+2컷, `GeneratePersonSegmentationRequest(.accurate)` 매트, `VNDetectFaceCaptureQualityRequest` 점수 게이트 | §6.3 B | ⏳ |
| T-303 | C 등급: `PhotosPicker`/파일 가져오기 → 정면 1장 적합성 검사(정면·눈 뜸·입 다묾·밝기) | §6.3 C | ⏳ |
| T-304 | `VisionCorrespondence`: 템플릿 패치를 가상 카메라로 투영해 Vision 76점 영역과 최근접 대응 생성·캐시 | §6.3 | ⏳ |
| T-305 | `CoursonaML.MonoDepthEstimator`: Depth Anything V2 small(Core ML, Apple 배포) 래퍼, 지연 로드·CPU 폴백, 얼굴 박스 영역만 추론 | §6.10, Q7 | ⏳ |
| T-306 | iPad 가로 거치 대응: `CaptureShotMeta.orientation` 기록, 피팅은 메타만 사용(초상 회전 버그 재발 방지) | §6.3 | ⏳ |
| T-307 | 🧪 실기기 체크리스트 1차: iPhone A 7컷 완주, Mac B 5컷 완주 | §9 | ⏳ |

## C4 · 단안 피팅 (B·C 등급)

| ID | 작업 | 근거(M-단계) | 상태 |
|---|---|---|---|
| T-401 | `MonoFitter` M1–M6: Vision 76점 대응 → 자세·스케일(s=1) → 의사 깊이 정합(2변수 최소제곱) → 3D TPS 패치 변형 → 깊이 당김(보수적) → F2 이하 공통 단계 합류 | M1–M6 | ⏳ |
| T-402 | 단위·합성 테스트: 76점 재투영 RMS < 2px, 의사 깊이 정합 잔차 중앙값 < 4mm, 자기교차 0 | §9 | ⏳ |
| T-403 | 🧪 Mac 실기기(FaceTime HD) B 등급 빌드 1회 | §9 | ⏳ |

## C5 · 텍스처·스플랫

| ID | 작업 | 근거 | 상태 |
|---|---|---|---|
| T-501 | `TextureBuilder` `faceOnly` 프리셋: 얼굴 UV + 캡 UV 섬(아틀라스 여백 우선, Q8) | §6.5 | ⏳ |
| T-502 | 눈 캡·입 캡 텍스처 투영(정면 중립 컷의 눈, 입 벌림 컷의 치아·입안) | §6.5 | ⏳ |
| T-503 | `CoursonaSplat`: 얼굴면 밖 삼각형 바인딩(≤60k), 색·불투명도 초기화, `splats.bin` | §6.6 | ⏳ |
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
