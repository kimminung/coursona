# 코르소나 (Coursona) — Tech PRD

> 새 프로젝트 · iOS 26 / iPadOS 26 / macOS 26 **세 플랫폼 모두 1차 입력 가능** · Swift 6 toolchain (Swift 5 언어 모드, 기본 MainActor 격리)
> 작성일 2026-10-05 · 상태: **v0.2 초안** — 구현 전. 근거는 초상(Chosang) 리포(형제 프로젝트, 로컬 보관, 이 리포에는 포함하지 않음) 커밋 `3d222a8` 의 코드·문서·실측치, Apple 개발자 문서(DocumentationSearch), Apple ML 공개 모델 자료.
> v0.1 → v0.2 변경: ① 눈알·입안 **분리 엔티티 폐기**, 블렌더 흉상 한 메시만 쓴다(§6.2·§6.4) ② Mac·일반 카메라도 **1차 입력**(§6.3 B 등급, §6.4 단안 경로) ③ 목표를 "Vision Pro 페르소나 같은 경험을 iPhone·iPad·Mac 에서" 로 상향, 라이브 구동 추가(§6.8) ④ Apple 제공 온디바이스 모델 채택표(§6.10), SHARP 는 라이선스 때문에 스파이크 전용.
> 이름 "코르소나" = 콜슨이 만든 페르소나. 초상(Chosang)·소반(Soban) 리포는 **읽기 전용 참고**, 수정하지 않는다. UI/UX 디자인 PRD 는 §13 을 입력으로 쓴다.

## 1. 한 줄 요약

**Vision Pro 의 페르소나처럼**, 내 촬영본으로 만든 흉상이 내 표정·고개·말에 맞춰 움직이는 경험을 **iPhone·iPad·Mac 에서** 온디바이스로 제공한다. 입력은 **TrueDepth(iPhone·iPad Face ID)** 가 최선이고, **일반 카메라(현존 Mac 전부, Face ID 없는 기기)** 와 **사진 1장**도 받는다. 기하의 진실은 초상에서 검증된 **블렌더 흉상 한 메시**뿐이다. 초상에서 눈알·입안을 따로 띄워 생긴 오차(돌출·어긋남)는 **분리 엔티티를 없애고 눈·입 구멍을 같은 메시 안에서 닫는 것**으로 제거한다. 흉상은 얼굴면만 보이게 투명 처리하고 나머지는 가우시안 스플랫으로 입체감만 준다. 모델이 필요한 곳은 Apple 이 제공하는 것(ARKit·Vision·FoundationModels·Apple 배포 Core ML 모델·RealityKit 스플랫)만 쓴다.

## 2. 초상에서 가져오는 것 · 바꾸는 것

| 영역 | 초상 (현행, 3d222a8) | 코르소나 (전환) |
|---|---|---|
| 흉상 템플릿 | `Default.chosangtemplate`(template.json schema 2 · bust.mesh CBM1 v2 · Template.usdz · EyesMouth.usdz). 정점 11,569 · 삼각형 22,996 · 패치 1,220/2,304 · LidInner 96 · LipInner 72. 눈알 `Eye_L/R`·입안 `Mouth_Inner` 는 **별도 메시** | **Bust 메시 하나만** 쓴다. `EyesMouth.usdz`·`Mouth_Inner` 는 반입하지 않는다. 눈·입 구멍은 앱이 로드 시 **캡(cap)으로 닫는다**(§6.2) |
| 눈·입 표현 | 눈알 구·치아 메시가 템플릿 위치에 고정 → 피팅 뒤 어긋나 눈꺼풀·입술을 뚫음 | 눈 = 눈꺼풀(블렌드셰이프) + **눈 캡 텍스처**(사진의 눈), 시선은 **캡 UV 이동**. 입 = 입술(셰이프) + **입 캡 텍스처**(입 벌림 컷의 치아·입안). 뚫릴 물체가 없다 |
| 캡처 | iPhone TrueDepth 5컷. Mac 은 Vision 76점 희소 폴백(품질 "기본") | **A 등급** TrueDepth 5+2컷(§6.3). **B 등급** 일반 카메라 5컷: Vision 76점 + **Depth Anything V2(Core ML, Apple 배포)** 의사(擬似) 깊이 + 인물 세그멘테이션. **C 등급** 사진 1장 가져오기 |
| 피팅 | 밀집(ARKit 1,220) 패치 치환 + RBF + 실루엣. 희소는 랜드마크 8점 TPS, s = 1 | 밀집 경로 유지 + **얼굴면 완성 단계**(§6.4). 단안 경로는 **76점 + 의사 깊이 + 실루엣 마스크**로 패치를 직접 당기는 `MonoFitter`(§6.4 M) |
| 렌더 | 흉상 전체 불투명 + 키트 오버레이 | **얼굴면 파트(패치 + 띠 + 캡)만 렌더**, 나머지는 파트 제외(투명). 머티리얼 4개(피부·눈 캡 L/R·입 캡) |
| 라이브 구동 | FaceRig(자동 깜빡임·시선·비셈), 라이브 표정은 iPhone ARKit 만 | iPhone·iPad: ARKit 52 그대로. **Mac: Vision 76점 → 12 셰이프 + 고개 자세**, 마이크 비셈(`HangulViseme`) 병행(§6.8) |
| 스플랫 | 계획만 | v1: 피팅 메시 바인딩 **정적 스플랫**(§6.6). SHARP 는 **스파이크만**(§6.10) |
| 패키지·전송 | `.chosang` schema 1, Bonjour `_chosang._tcp` | `.coursona` schema 2(= `.chosang` 상위호환) + `caps.json` + `splats.bin` + 입력 등급 기록. 어느 기기에서 만들었든 **세 플랫폼에서 동일 렌더**. A 등급으로 **업그레이드 병합**(§6.9) |

## 3. 배경 제약 (사실 → 결정)

| 제약 | 사실 | 결정 |
|---|---|---|
| TrueDepth 깊이 | `ARFaceTrackingConfiguration.isSupported` 는 Neural Engine 기기면 true 지만 **`ARFrame.capturedDepthData` 는 TrueDepth 세션에서만** 온다(ARKit 문서). 실기기 깊이는 ARKit 메시보다 −21 … −30 mm(초상 §28) | 등급 판정 = `isSupported` **그리고** 2 초 안에 깊이 1 프레임. 통과 = A 등급, 아니면 B 등급으로 **자동 전환**(막지 않는다). `DepthRegistration` 유지, `AVDepthData.cameraCalibrationData` 저장 |
| Mac 카메라 | FaceTime HD 는 깊이·ARKit 얼굴 추적이 없다. Vision `DetectFaceLandmarksRequest`(76점, 눈·눈썹·코·입 안/밖·동공·윤곽) + `FaceObservation` yaw/pitch/roll, `GeneratePersonSegmentationRequest`(인물 매트), `VNDetectFaceCaptureQualityRequest` 는 있다 | B 등급 입력 = 76점 + 자세 + 인물 매트 + **의사 깊이**. 절대 치수는 모르므로 **s = 1(눈 간격 64 mm 가정)** 명시, 품질 카드에 "치수 추정" 표시 |
| 단안 깊이 모델 | Apple Core ML 모델 갤러리(developer.apple.com/machine-learning/models)에 **Depth Anything V2 small**(24.8M, F16/INT8 mlpackage, Hugging Face `apple/coreml-depth-anything-v2-small`, Apache-2.0)이 있다. 상대 깊이(역깊이)만 출력, 커뮤니티 측정 iPhone 12 Pro Max 31 ms | 얼굴 영역 상대 깊이 → **눈 간격·코 높이 사전값으로 스케일·오프셋 정합**해 "의사 깊이 컷" 생성. 밀집 경로의 포인트 클라우드와 같은 자료형으로 넣는다(§6.4 M3). 모델은 앱 번들 동봉(≈ 50 MB F16) |
| SHARP | Apple ML Research "Sharp Monocular View Synthesis in Less Than a Second"(2025-12, `apple/ml-sharp`): 사진 1장 → 3DGS, 미터 척도. 가중치 라이선스는 **Apple Machine Learning Research Model License — 연구·비상업 전용, 제품 사용 금지**. 커뮤니티 Core ML 포트 M4 Max 1.9 s, 출력 ≈ 118만 스플랫 | **제품 경로에 넣지 않는다**. Mac 스파이크(S-1)로 "얼굴면 밖 스플랫 품질 상한" 을 재는 데만 쓰고, 결과 수치만 문서에 남긴다. 제품 스플랫은 §6.6 자체 초기화 |
| 생성 모델 | FoundationModels 온디바이스 LLM 은 `Attachment(이미지)` 로 사진을 읽고 `@Generable` 로 구조화 응답(OS 27). 이미지 **생성**은 안 한다. Image Playground `ImageCreator` 는 양식화 이미지라 텍스처 보정에 부적합 | FoundationModels 는 **분류·힌트·설명**(외형 힌트, 품질 카드 문장, 재촬영 안내)에만. 픽셀·좌표는 결정적 파이프라인 |
| 흉상 구멍 | Bust 메시의 눈 구멍은 LidInner 2열(눈알 반지름 −0.2/−1.5 mm 구면 위)로 끝나고 중앙이 비어 있다. 입도 LipInner 2열 뒤가 비어 있다(블렌더 `bust_build.py eye_band/mouth_band`). 초상은 그 뒤를 눈알·입안 메시가 채웠다 | 로드 시 **각 구멍의 안쪽 고리(눈 24·입 36)를 캡으로 닫는다**: 눈은 피팅된 가상 눈알 구면 위 팬(fan) 캡, 입은 안쪽 고리를 뒤로 6 mm 밀어 넣은 포켓 캡. 같은 `LowLevelMesh` 의 별도 파트. 블렌더 변경 없음(제안은 Q6) |
| 런타임 변형 | `LowLevelMesh` + `LowLevelDeformation`(기기·Mac GPU 0.09 ms), 시뮬레이터 CPU 폴백 | 그대로. 캡 정점은 변형 버퍼에 포함(눈 캡은 눈 셰이프 델타 0, 입 캡은 입술 안쪽 띠 평균 변위) |
| 투명 처리 | `PhysicallyBasedMaterial.blending = .transparent(opacity:)` 가능하지만 완전 투명도 드로우 비용은 남는다 | 얼굴면 밖 삼각형은 **파트에서 제외**. 고스트(opacity 0.15) 파트는 디버그·폴백 전용 |
| 스플랫 | RealityKit 27 `GaussianSplatComponent` + `GaussianSplatResource.BufferResource`(position f3·scale f3·rotation f4·opacity f1·SH ≥ f3, half 가능, `LowLevelBuffer` 참조). **시뮬레이터 SDK 에 없음** | 기기·Mac 스플랫, 시뮬레이터 고스트 메시 |
| 라이브 구동(Mac) | ARKit 없음. Vision 76점은 실시간(FaceTime HD 1080p, 초상 T-205 실측 30 fps 추적) | 76점 → 셰이프 12종(§6.8). 정밀도는 A 등급보다 낮다고 UI 에 표시하지 않고 **자연스럽게 보이게 스무딩**한다 |
| USD 쓰기 | ModelIO usdc/usda ✓ usdz ✗(초상 T-005) | 내보내기는 선택(§6.9) |
| 참고 리포 | 초상·소반 수정 금지 | `ChosangKit` 을 **복사**해 `CoursonaKit`(§6.1) |

## 4. 목표 / 비목표

**목표 (v1)**
1. 세 등급 입력 모두에서 **같은 `.coursona`** 가 나오고, iPhone·iPad·Mac 에서 **같은 모습**으로 렌더된다. A 등급 iPhone 15 Pro 90 s, B 등급 Mac(M 시리즈) 60 s, C 등급 30 s.
2. **얼굴면 완성**: 분리 물체가 없으므로 "뚫림" 은 정의상 0. 남는 결함 지표는 ① 눈꺼풀 띠·캡 자기교차 0 ② 입술 띠·입 캡 자기교차 0(52 셰이프 각 1.0 + 캡처 가중치) ③ 눈 캡 동공 중심 오차 < 1.5 mm(A), < 3 mm(B).
3. **라이브 구동**: iPhone·iPad 는 ARKit 52 + 고개, Mac 은 Vision 12 셰이프 + 고개 + 마이크 비셈. 거울 화면에서 지연 < 120 ms, 60 fps.
4. 투명 흉상 + 스플랫: 옆·뒤에서 봐도 머리·목·어깨 형태가 있다.
5. 초상 `.chosang` 을 연다(하위호환). 코르소나 `.coursona` 의 identity.bin 은 v3 이지만 "v2 로 저장" 옵션으로 초상도 읽을 수 있다(눈·입 캡은 초상이 모른다).

**비목표 (v1)**
- 블렌더 템플릿 재제작·템플릿 2종, 머리카락 라이브러리 품질, 실사 머리카락.
- 스플랫 학습(미분 가능 래스터라이저), SHARP 제품 탑재.
- visionOS 빌드, 소반 어댑터, 클립 저작, FaceTime 가상 카메라(Camera Extension, v2 §11).
- 원격 서버·계정·생성형 이미지 보정.

## 5. 사용자 흐름

```
[공통 시작]  기기 등급 판정(A: TrueDepth / B: 일반 카메라 / C: 사진 가져오기) — 막지 않고 등급만 바꾼다

[A · iPhone/iPad Face ID]  7컷 가이드(필수 5: 정면·좌·우·위·미소 / 선택 2: 눈 감기·입 벌림)
[B · Mac, Face ID 없는 iPhone/iPad]  5컷 가이드(같은 각도, Vision 자세로 게이트) + 선택 2
[C · 사진 1장]  정면 사진 선택 → 품질 검사(VNDetectFaceCaptureQuality, 정면 ±10°)

  ─▶ 빌드(피팅 → 얼굴면 완성 → 텍스처 → 스플랫, 진행률 4단계, 등급별 시간)
  ─▶ 검수(턴테이블 · 자기교차 배지 · 포즈 토글 · 투명도/스플랫 토글 · 품질 카드 · 등급 표시)
  ─▶ 거울(라이브 구동: 내 얼굴을 따라 움직임) ─▶ 저장(.coursona) ─▶ 보내기/AirDrop/파일
[업그레이드]  B·C 로 만든 페르소나를 iPhone 에서 A 로 다시 찍으면 **같은 항목으로 병합**(§6.9)
```

## 6. 시스템 구성

### 6.1 패키지 구조

로컬 Swift Package `CoursonaKit` + 앱 타깃 `Coursona`(iOS·iPadOS·macOS 한 타깃). 초상 `ChosangKit` 을 파일 단위로 복사해 시작하고 모듈명만 바꾼다. 초상 리포를 경로로 참조하지 않는다.

| 모듈 | 초상 출처 | 코르소나에서 | 상태 |
|---|---|---|---|
| `CoursonaCore` | `ChosangCore` 전부 | `Identity` v3(regionDeltas·caps), `CaptureShotMeta` 에 등급·의사 깊이·세그먼트 마스크 | 복사 + 수정 |
| `CoursonaCapture` | `FaceCaptureSession`(A) · `PhotoCaptureSession`(B) · `CaptureGuide` · `SpeechGuide` · `MicLevelMeter` · `FacePoseConvention` | 등급 판정, 7/5컷 상태기계, 깊이 필수(A), Vision 매트·품질 점수(B), 사진 가져오기(C) | 복사 + 수정 |
| **`CoursonaML`** (신규) | — | Apple 배포 Core ML 모델 래퍼: `MonoDepthEstimator`(Depth Anything V2 small), 지연 로드·캐시·CPU 폴백. 스파이크용 SHARP 러너는 **별도 Mac 전용 타깃** `coursona-spike`(제품 번들에 안 들어감) | 신규 |
| `CoursonaFit` | `FacePatchSolver`·`FaceFitter`·`SilhouetteFitter`·`DeltaCalibrator`·`SparseFitter`·`AppearanceHints` | 밀집 경로 수정(실루엣 제외), **`MonoFitter`**(단안 경로, `SparseFitter` 확장) | 복사 + 수정 + 신규 |
| **`CoursonaFace`** (신규) | — | 얼굴면 완성: `EyeOpeningSolver`·`InnerBandBuilder`·`CapBuilder`·`SelfIntersectionCheck`·`UserShapeDeltas` | 신규 |
| `CoursonaTexture` | `TextureBuilder` 5단계 + Metal + `TextureRegions` + `SmileVerification` | `faceOnly` 프리셋, **눈 캡·입 캡 텍스처**, B 등급 가시성(깊이 대신 매트) | 복사 + 수정 |
| **`CoursonaSplat`** (신규) | — | 스플랫 바인딩·초기화·`splats.bin`·`GaussianSplatResource` 브리지·폴백 | 신규 |
| `CoursonaRig` | `BustEntity`·`FaceRig`·`ClipPlayer`·`TemplateLoader` | 파트 4+1, 캡 머티리얼·UV 시선, regionDeltas | 복사 + 수정 |
| **`CoursonaDrive`** (신규) | 초상 `FaceRigSystem` 일부 | 라이브 구동 소스 추상화: `ARKitFaceDriver`(iOS) · `VisionFaceDriver`(macOS·폴백) · `MicVisemeDriver`, 스무딩·합성 | 신규 |
| `CoursonaIO` | `ChosangPackageStore`·`CaptureBundleStore`·`TemplateStore`·`ZipArchive`·`ImageCodec`·`ChosangTransfer`·`USDExport` | `.coursona` schema 2, caps/splats, 서비스명, 병합 | 복사 + 수정 |
| `coursona-validate` CLI | `chosang-validate` | `--fit`(등급별 지표), `--mono`(사진 → 의사 깊이 PNG), `--splat` | 복사 + 수정 |

규칙(초상 CLAUDE.md 계승, 단 Combine 은 **허용**으로 변경): 순수 모델·수학은 Foundation/simd/CoreGraphics 만, 비동기 흐름은 async/await 를 기본으로 하되 **Combine 을 금지하지 않는다**(연속 스트림이 자연스러운 곳 — 예: `VisionFaceDriver`·`MicVisemeDriver` 의 실시간 신호 합성, 캡처 게이트의 디바운스 — 에서는 `Publisher` 체인을 async/await 와 함께 쓸 수 있다), `#if os(iOS)`/`#if os(macOS)`, Metal 소스는 `resources: [.copy("Shaders")]` + 런타임 컴파일, Swift Testing, 캡처 데이터·Core ML 가중치 외 대용량은 커밋 금지(모델은 LFS 또는 첫 실행 다운로드 — Q7).

### 6.2 템플릿 반입 · 한 메시 · 투명 흉상

- 반입: 초상 `Default.chosangtemplate` 의 `template.json`·`bust.mesh`·`Template.usdz`(교차 검증용)·`textures`·`clips` 만. **`EyesMouth.usdz` 와 `Mouth_Inner` 관련 메타(`mouthInnerShapes`)는 쓰지 않는다.**
- **얼굴면(FaceSurface)** = 세 꼭짓점이 모두 `ARKitFace ∪ LidInner ∪ LipInner` 인 삼각형 + 앱이 만든 **캡 삼각형**. 로드 시 인덱스를 `[패치+띠][눈 캡 L][눈 캡 R][입 캡][나머지]` 순으로 재배열해 `LowLevelMesh.Part` 5개로 올린다(`FaceSurfacePartition`, 결정적·캐시). 렌더 메시 솔기 분할(11,569 → 11,931)은 `sourceIndex` 로 그룹을 따라간다.
- **캡 기하(`CapBuilder`)** — 템플릿 로드 시 템플릿 값으로 1회, 피팅 뒤 피팅 값으로 다시:
  - 눈 캡(각 24 고리 → 중심 1 + 링 1 추가 = 49 정점·72 삼각형): 안쪽 고리(LidInner 2열, 반지름 r−1.5 mm 구면 위)에서 가상 눈알 중심 c·반지름 r 의 **구면 캡**. 중심 정점 = c + n_face·(r − 1.5 mm), 중간 링은 고리와 중심의 구면 보간. UV 는 캡 전용 섬(`uvRegions.lid_L/lid_R` 안쪽 빈 영역을 쓰거나, 없으면 아틀라스 여백 256² 두 칸 — 로드 시 결정, Q8).
  - 입 캡(36 고리 → 뒤로 6 mm 민 복제 고리 36 + 바닥 중심 1 = 73 정점·108 삼각형): 안쪽 고리를 −Z 로 6 mm·s, 위아래로 1.5 mm 벌려 **포켓** 을 만든다. 입을 다물면 보이지 않고 벌리면 포켓 안쪽(치아·혀 텍스처)이 보인다.
- **투명 = 파트 제외**. 기본 렌더는 얼굴면 4 파트. 나머지 파트는 디버그 토글·시뮬레이터 폴백에서만 opacity 0.15 고스트.
- 얼굴면 외곽(56점 루프)은 투명 영역과 맞닿는다. 스플랫이 외곽 안쪽 2 링까지 덮어 가장자리를 가린다(§6.6).

> **구현 노트(C1, 2026-10-05)** — `CapBuilder` v0 은 위 서술과 달리 블렌더 `eye_band`/`mouth_band` 상수(0.0002/0.0015/0.006 m 등)를 추측 재현하지 않는다. 대신 `Geometry.boundaryLoops`(경계 변 위상 탐색)로 각 구멍의 **실제 열린 테두리**를 직접 찾아 중간 고리(신규 정점) + 중심(신규 정점) 하나로 닫는다. 눈·입 중심 시드에서 20 mm 안의 가장 가까운 경계 고리만 닫아 목/어깨 절단면과 혼동하지 않는다. 블렌더가 이미 만들어 둔 LidInner/LipInner 안쪽 띠(ring1·ring2)는 그대로 두고 그 **뒤의 열린 구멍만** 추가로 막으므로, "안쪽 고리가 몇 번째 LidInner 인덱스인지" 추측할 필요가 없다 — `InnerBandIndexMap`(§6.4 F5 서술)은 **불필요해졌다**. 파트는 서술된 5개가 아니라 **2개**(얼굴면 하나로 합침·나머지)이며, 눈 캡·입 캡은 별도 파트가 아니라 얼굴면 파트에 포함된다(머티리얼이 같으므로 나눌 이유가 없다). C2 의 F6(피팅 좌표로 다시 닫기)도 같은 `CapBuilder` 를 피팅된 `Identity.positions` 에 대해 다시 호출하면 되고, 새 구현이 필요 없다. 구현: `CoursonaFace/CapBuilder.swift`, `CoursonaCore/FaceSurfacePartition.swift`, `CoursonaCore/Math/Geometry.boundaryLoops`.

### 6.3 캡처 (`CoursonaCapture`)

| 항목 | A 등급 (TrueDepth) | B 등급 (일반 카메라: Mac 전부, Face ID 없는 iPhone/iPad) | C 등급 (사진 1장) |
|---|---|---|---|
| 판정 | `isSupported` + 2 초 내 깊이 수신 | A 실패 또는 Mac | 사용자가 "사진으로 만들기" 선택 |
| 세션 | 초상 `FaceCaptureSession`(8 프레임 평균 1,220 정점·52 가중치, 포트레이트 회전 규약) + `cameraCalibrationData` 저장 + **깊이 없는 프레임은 셔터 불가** | 초상 `PhotoCaptureSession`(AVCapture 1080p + `DetectFaceLandmarksRequest` revision 3 76점 + yaw/pitch/roll, 8 프레임 평균) + `GeneratePersonSegmentationRequest(.accurate)` 매트 + `VNDetectFaceCaptureQualityRequest` 점수 | `PhotosPicker`/파일 → 같은 Vision 요청 1회 |
| 컷 | 필수 5(정면·좌·우·위·미소) + 선택 2(눈 감기 `eyeBlink ≥ 0.8`, 입 벌림 `jawOpen ≥ 0.5`). 게이트 초상 19차(yaw ±14°·pitch ±12°·유지 0.5 s·유예 0.35 s) | 필수 5 + 선택 2. 게이트는 Vision 자세(±12/±10, 초상 사진 폴백 값) + 품질 점수 ≥ 0.5. 눈 감기는 눈 종횡비 < 0.12, 입 벌림은 안쪽 입술 간격/입 폭 > 0.25 로 판정 | 정면 1컷(yaw·pitch ±10°), 눈 뜸·입 다묾 확인 |
| 깊이 | 640×480 Float32 + 캐시 0.6 s, 저장 시 5/5 검증 | **의사 깊이**: 정면·좌·우 컷에 `MonoDepthEstimator`(Depth Anything V2 small, 518 입력) → 얼굴 박스 영역 상대 깊이 → `CaptureShotMeta.pseudoDepth`(파일 `mono-i.f16`, 매트 `matte-i.png`) | 정면 1장 의사 깊이 |
| iPad | 가로 거치 흔함 → `CaptureShotMeta.orientation` 기록, 피팅은 메타만 사용 | 동일 | — |
| 번들 | `.chosangcapture` 포맷 유지 + `tier: "A"/"B"/"C"`, `kinds` 에 `eyesClosed`·`mouthOpen`, 의사 깊이·매트 파일 | 동일 | 동일 |

Vision 76점 ↔ 템플릿 랜드마크 대응은 초상 `template.json landmarks`(14) + `SparseFaceGeometry` 규약(핵심점 좌/우는 이미지 x, yaw 부호는 코끝, pitch 는 Vision 부호 반전)을 그대로 쓴다. 76점 전체 대응(`visionIndices`)은 template.json 에 비어 있으므로 **앱이 템플릿 패치를 정면 가상 카메라로 투영해 Vision 영역(눈 윤곽·입술 안/밖·코·턱선)과 최근접으로 1회 만들어 캐시**한다(`VisionCorrespondence`, 영역별 호 길이 매개변수화).

### 6.4 피팅 — 얼굴면 완성 (`CoursonaFit` + `CoursonaFace`)

#### 밀집 경로 (A 등급)

```
F1 FacePatchSolver     컷 정렬·중립화·평균 → 사용자 패치 1,220 · s · 컷별 alignment              (초상 그대로)
F2 EyeOpeningSolver    가상 눈알 중심·반지름(눈꺼풀 회전축·캡 곡률용) — 눈 루프 24×2 + 눈 감기 컷     (신규)
F3 HeadPropagator      전역 유사변환 + RBF 잔차 + 목 감쇠 + 어깨 s + 대칭 70%                       (초상 그대로)
F4 SilhouetteFitter    깊이 → 두상·귀·목 당김. 눈·입 **제외 영역**(띠 + 루프 2-링, 루프 투영 안 깊이점)  (수정)
F5 InnerBandBuilder    LidInner 96 · LipInner 72 를 피팅된 루프 + 가상 눈알 구로 재생성(블렌더 공식·s 배)  (신규)
F6 CapBuilder          눈 캡 2 · 입 캡 생성(§6.2) → caps.json(정점은 identity.bin v3 에)             (신규)
F7 UserShapeDeltas     eyeBlink_L/R · jawOpen 패치 델타를 사용자 컷으로 치환(선택 컷 있을 때)           (신규)
F8 RegionDeltaBuilder  띠·캡의 셰이프 델타 재생성(눈 8종은 c 기준 회전, 입은 띠 평균 변위)              (신규)
F9 SelfIntersectionCheck 중립 + 52×1.0 + 캡처 가중치 → 띠↔캡·윗입술↔아랫입술·눈꺼풀 위↔아래 교차 0     (신규)
F10 DeltaCalibrator    jawOpen 진폭(미소 컷) — F7 이 치환했으면 생략                                (초상 그대로)
```

- **F2** 는 v0.1 의 눈알 피팅과 같은 수학(사전값 r = 0.012·s, 중심 = 루프 중심 − n·√(r²−ρ²); 눈 감기 컷이 있으면 감은 눈꺼풀 표면이 구 + 1.0 mm 바깥에 오도록 4 변수 최소제곱)이지만 **용도가 바뀐다**: 렌더할 눈알이 아니라 ① 눈꺼풀 셰이프 회전축 ② 눈 캡 곡률 ③ 눈 캡 텍스처의 동공 중심이다. 실기기 사전값 13.5 mm(초상 §28) 기준선.
- **F5** 는 블렌더 `eye_band`(1열 r−0.2 mm, 2열 (P−c)+(0,6 mm,0) 방향 r−1.5 mm)·`mouth_band`(위아래 2.8/6.8 mm, 앞뒤 ±1.2/±3.2 mm, 꼬리 수축 4 %/10 %)를 Swift 로 재현, 모든 mm 상수에 s 를 곱한다. 템플릿을 넣으면 bust.mesh 와 0.0 mm 일치(테스트). LidInner·LipInner 인덱스 ↔ 루프 순서는 로드 시 최근접(0.5 mm 임계)으로 추론·캐시(`InnerBandIndexMap`).
- **F9** 가 v0.1 의 관통 검사를 대체한다. 분리 물체가 없으므로 검사 대상은 **자기교차**뿐: 각 포즈에서 (a) LidInner 2열과 눈 캡 링의 부호 거리(캡 구면 기준) ≥ 0 (b) 입 캡 포켓 벽과 LipInner (c) 윗입술 안쪽 띠와 아랫입술 안쪽 띠(`mouthClose`·`mouthPress` 1.0 에서 겹침 ≤ 0.3 mm 허용) (d) 윗눈꺼풀 띠와 아랫눈꺼풀 띠(`eyeBlink` 1.0 에서 ≤ 0.3 mm). 위반 시 F5 의 띠 깊이 상수를 0.5 mm 씩 조정해 최대 3회 재시도, 남으면 `quality.selfIntersections` 기록 + 경고 배지.

> **구현 노트(C2, 2026-10-06)** — C1 의 `CapBuilder`(위상으로 테두리를 직접 찾는 방식)를 그대로 쓰면서 F2·F5·F6·F7·F8·F9 의 범위가 위 서술보다 훨씬 줄었다.
> - **F2**: 새 코드가 필요 없다. 초상에서 포팅한 `FacePatchSolver.estimateEyes` 가 이미 같은 사전값+구 피팅을 한다. 눈 감기 컷으로 보강하는 부분만 C3 이후(그 컷 자체가 캡처 경로에 아직 없다).
> - **F5(InnerBandBuilder)는 통째로 불필요해졌다.** LidInner·LipInner 는 C1 에서 전혀 건드리지 않는다(기존 위치·삼각형 그대로 둔다) — "안쪽 2열이 LidInner 의 몇 번째 인덱스인지" 추론할 필요가 `CapBuilder` 설계 단계에서부터 없었다. `InnerBandIndexMap` 은 만들지 않는다.
> - **F6(v1, 피팅 좌표로 다시 닫기)도 새 코드가 없다.** `BustEntity.init` 이 `identity.positions`(정점 수가 템플릿과 같으면, 즉 진짜 피팅 결과면) 를 템플릿에 대입한 뒤 **C1 과 똑같은** `CapBuilder.addingCaps` 를 다시 부른다. 템플릿 좌표(v0)와 피팅 좌표(v1)가 함수 레벨에서 구분되지 않는다.
> - **F8(RegionDeltaBuilder)** 은 "피팅된 눈알 중심 기준 회전" 대신 더 단순하게: 캡이 새로 만든 정점(중간 고리·중심)에 **그 캡이 붙은 테두리(기존 정점)의 평균 델타**를 준다. `CapBuilder.addingCaps` 안에서 셰이프마다 수행하고, `shapeDeltas` 확장은 예전의 "0 으로 채운다"를 대체한다.
> - **F9**는 진짜 삼각형-삼각형 교차 대신 **법선 뒤집힘 근사**로 구현했다(`SelfIntersectionCheck`): 중립 자세의 캡 삼각형 법선과 셰이프 1.0 자세의 같은 삼각형 법선이 반대를 향하면(내적 < 0) "뒤집힘" 으로 센다. 4종 분류·재시도 로직은 v1 에서 빠졌다 — 뒤집힘이 나오면 0.0.1 절 F5/F6 쪽에서 더 손볼 지점을 알려 주는 진단으로만 쓴다.
> - **identity.bin v3·`caps.json` 은 필요 없어졌다.** 캡 기하와 F8 델타는 (템플릿, 피팅된 `Identity.positions`) 만으로 로드할 때마다 결정적으로 다시 계산된다 — 저장할 사용자별 데이터가 없다. identity.bin 은 v2 그대로 쓴다(§6.9 의 "v3" 서술은 더 이상 유효하지 않다 — 패키지 포맷은 C7 에서 재확인한다).
> - **F7(UserShapeDeltas)은 그대로 C3 이후로 차단**이다 — 눈 감기·입 벌림 컷이 캡처 경로(`ShotKind`)에 없다.
> 구현: `CoursonaFit/SilhouetteFitter.swift`(F4: `excludeEyeMouthRegion`), `CoursonaFace/CapBuilder.swift`(F6·F8 합침), `CoursonaFace/SelfIntersectionCheck.swift`(F9), `CoursonaRig/BustEntity.swift`(피팅 좌표 대입).
>
> **구현 노트(C3, 2026-10-06)** — `ShotKind` 에 `eyesClosed`·`mouthOpen`(둘 다 `isOptional`) 을 추가해 F7 의 차단을 풀었다.
> - A 등급(`FaceCaptureSession`): `FaceFrameStatus.eyeBlinkAvg`/`jawOpenWeight` + `CaptureGate.eyesClosedMinBlink(0.8)`/`mouthOpenMinJaw(0.5)` 로 두 선택 컷을 게이팅.
> - B 등급(`PhotoCaptureSession`): Vision 눈/입 랜드마크 바운딩박스에서 계산한 `eyeAspectRatio`/`mouthOpenRatio` + 같은 자리 게이트로 동일 기능.
> - **F7(`CoursonaFit/UserShapeDeltas.swift`)**: 그 컷의 정렬된 ARKit 패치에서 "다른 셰이프가 이미 설명하는 변위"(다른 블렌드셰이프 가중치 × 템플릿 델타)를 뺀 뒤, 목표 셰이프 가중치로 나눠 1.0 기준 델타로 되돌린다. `FaceFitter.fit` 에 `FitOptions.calibrateUserShapes`(기본 on)로 연결 — F10(`DeltaCalibrator.jawOpen`, 미소 컷 기반 진폭 스케일)보다 먼저 적용되고 성공하면 F10 결과를 덮어쓴다.
> - 합성 테스트(`UserShapeDeltasTests`)로 F7 이 F10 보다 실제로 더 정확한 상황을 확인했다: 사용자의 진짜 jawOpen 모양이 템플릿 델타의 **단순 배율이 아니라**(배율이면 F10 의 스칼라 최소제곱이 이미 거의 최적이라 비교가 무의미하다) 정점별로 다르게 흔들리는 모양일 때, F10 은 스칼라 하나로만 늘리고 줄일 수 있어 그 흔들림을 전혀 설명 못 해 RMS 3.0 mm 가 나고, F7 은 컷을 직접 읽어 RMS 0.75 mm(640×480 합성 캡처 자체의 노이즈 바닥치)로 4 배 더 정확하다. 균일한 평행이동을 섭동으로 쓰면 컷 정렬(F1)의 강체 변환이 그대로 상쇄해 차이가 안 보인다는 함정도 확인(테스트 주석에 남김).
>
> **추가(T-301, 2026-10-05)** — "저장 시 5/5 깊이 검증"은 `CoursonaCapture/DepthCoverage.swift` 로 완료: 필수 5컷(선택 2컷 제외) 중 깊이가 없는 걸 찾아 한글 안내 문장(어떤 컷을 다시 찍어야 하는지)까지 낸다. 순수 로직이라 합성 번들로 단위 테스트 4개. `coursona-validate --fit` 에도 연결해 실제 캡처 번들을 열어볼 때 바로 보인다.
> `AVDepthData.cameraCalibrationData` 저장은 **의도적으로 보류**했다 — `DepthRegistration`(C0 포팅분, 깊이·메시 z 차의 중앙값을 재서 빼는 경험적 보정)가 이미 동작하고 있고, calibration 데이터는 TrueDepth 가 없는 시뮬레이터로는 실제 필드(좌표 규약·부호)를 검증할 방법이 없다. 검증 없이 손대면 초상(Chosang)의 회전 버그처럼 실기기에서만 드러나는 오류를 만들 위험이 더 크다고 판단했다 — 🧪 실기기 확보 후 재검토.
>
> **추가(T-302, 2026-10-05)** — B 등급 캡처 품질 점수·인물 매트 게이트. 새 Vision API 라 `RunCodeSnippet`(Xcode MCP) 로 실제 배포 타깃(OS 26)에서 컴파일이 되는지부터 먼저 확인했다(문서만으로는 가용성을 확신할 수 없었다):
> - **캡처 품질**: `DetectFaceCaptureQualityRequest` → `FaceObservation.captureQuality.score`(0…1). OS 26 에서 바로 된다. `PhotoCaptureGate.minCaptureQuality`(0.5, TechPRD §6.3 그대로)로 게이팅.
> - **인물 매트**: `GeneratePersonSegmentationRequest` 의 결과 전체(알파 마스크 이미지)를 꺼내는 `.pixelBuffer` 접근자는 **OS 27+ 가 필요하다** — `RunCodeSnippet` 으로 실제로 "only available in macOS 27.0 or newer" 컴파일 오류를 받아 확인했다(이 프로젝트 배포 타깃은 OS 26). 전체 매트 이미지를 저장해 배경을 제거하는 원래 계획은 **보류**한다.
>   대신 같은 요청의 `pixel(at: NormalizedPoint)`(점 단위 샘플링)는 OS 26 에서 이미 된다 — 얼굴 상자를 5×5 그리드로 샘플링해 "이 상자가 실제로 사람으로 분류되는가" 비율을 게이트 신호로만 쓴다(`PersonCoverage.swift`). 배경 제거(텍스처 투영에서 벽지를 피부색으로 오인하는 문제)는 여전히 못 푼다 — 배포 타깃을 OS 27로 올릴 때 `.pixelBuffer` 로 재검토.
> - 샘플링 로직(`PersonCoverage.ratio`)은 Vision 타입을 몰라도 되게 클로저로 분리해 순수 로직으로 테스트한다(5개). `PhotoSuitability`(T-303, C 등급)도 같은 두 값을 받도록 확장 — 기본값 1(측정 안 함)이라 기존 호출부는 그대로 통과한다.
>
> **추가(T-306, 2026-10-05)** — iPad 가로 거치 기록. `CoursonaCore` 에 `CaptureOrientation`(7종, `UIDeviceOrientation` 과 같은 뜻) 을 추가하고 `CaptureShotMeta.orientation` 에 담는다. `FaceCaptureSession`(A 등급) 이 촬영 순간 `UIDevice.current.orientation` 을 그대로 매핑해 기록하지만, **영상·깊이·좌표 회전 수학은 조금도 바꾸지 않았다** — 지금도 늘 세로(포트레이트) 거치를 가정해 처리한다. 이렇게 보수적으로 간 이유: 초상(Chosang)의 회전 버그가 정확히 "회전 관련 수학을 실기기 검증 없이 건드려서" 난 문제였고, 지금도 TrueDepth 가 없는 시뮬레이터로는 실제 가로 거치 상황을 재현할 수 없다 — 기록만 해 두면 나중에 실기기로 가로 거치 사진을 받아서 **그때** 안전하게 분기를 넣을 수 있다.
> 문서(Apple)에 `UIDevice.orientation` 은 `beginGeneratingDeviceOrientationNotifications()` 를 부르기 전엔 항상 0(`.unknown`)을 돌려준다고 명시돼 있다 — 실기기 없이는 몰랐을 함정이라 `start()`/`stop()` 에 시작·종료 호출을 추가했다. Codable 왕복 단위 테스트 3개(`CaptureOrientationTests`) — 매핑 함수 자체(`FaceCaptureSession.captureOrientation`)는 iOS 전용이라 macOS 에서 돌리는 `swift test` 로는 못 검증한다(🧪 실기기).
>
> **실기기 디버깅(T-307, 2026-10-05) — 확정된 결론: 로직은 처음부터 맞았다.** iPhone 16·MacBook Air M4 1차 실기기 테스트에서 `TierClassifier` 가 TrueDepth 가 있는 iPhone 16 을 A 가 아니라 B 로 판정하는 것처럼 보이는 문제가 반복됐다(2회). 추적 과정:
> 1. 1차 가설(타이밍): 최초 실행 시 카메라 권한 팝업 응답 시간이 `detectAutomaticTier` 의 2초 깊이-대기 윈도를 깎아먹을 수 있다고 보고 `AVCaptureDevice.authorizationStatus(for:) == .notDetermined` 면 먼저 묻고 기다리도록 고쳤다 — 유효한 개선이지만, 권한을 이미 승인한 뒤 재실행에서도 B 가 나와서 **이게 근본 원인이 아니었음**이 드러났다.
> 2. 더 추측하지 않고 `ContentView` 에 임시로 실시간 미리보기 + `isSupported`/권한/추적·깊이 상태를 전부 화면에 띄우는 진단 코드를 넣어 실기기에서 직접 확인했다. 결과: **TrueDepth 지원 예 · 권한 허용됨 · 얼굴 인식 예 · 최종 등급 A.** "깊이 수신 아니오" 로 보였던 건 버그가 아니라 TrueDepth 깊이 프레임이 컬러 프레임과 주기가 달라 매 프레임 오지 않는 정상 동작(코드 주석에 이미 있던 내용)이 멈춘 순간 우연히 그 프레임이었을 뿐이다.
> **진짜 원인**: `ContentView`(C0 자리표시자) 가 라이브 미리보기 없이 백그라운드에서 조용히 2초만 보고 끝나는 구조라, 사용자가 그 2초 동안 카메라를 보고 있지 않으면(안내가 전혀 없으니 당연히 그럴 수 있다) 얼굴이 안 잡혀 B 로 떨어지는 **테스트 방법론 문제**였다 — `TierClassifier` 코드 자체에는 수정이 필요 없었다(권한 대기 개선만 유효하게 남긴다).
> **제품 요구사항으로 확정**: C8 에서 실제 캡처 진입 화면을 만들 때는 등급 판정 중 반드시 라이브 미리보기(또는 최소 "카메라를 봐주세요" 안내)를 같이 보여줘야 한다 — 지금처럼 안내 없이 조용히 판정하면 실사용자도 똑같이 헷갈릴 것이다. 진단에 쓴 임시 UI 코드는 확인 후 바로 원래 자리표시자로 되돌렸다(C8 전까지 `ContentView` 는 계속 최소 상태로 유지).

#### 단안 경로 (B·C 등급) — `MonoFitter`

```
M1 Vision 76점 → 템플릿 대응(VisionCorrespondence, 눈 윤곽 2×8 · 입술 안/밖 6+14 · 코 8 · 윤곽 17 · 눈썹 2×6 · 동공 2)
M2 자세·스케일   정면 컷: 눈 간격 64 mm 가정으로 카메라 깊이 결정(s = 1), 좌·우·위 컷은 Vision yaw/pitch + Procrustes(2D) 로 정렬
M3 의사 깊이 정합  Depth Anything 상대 깊이 d(u,v) → 얼굴 박스 안에서 z = a·d + b 를 "코끝–눈꼬리 깊이차 사전값(템플릿 ×s)" 과
                 76점의 템플릿 깊이로 최소제곱(2 변수 + 강건 가중) → 미터 의사 깊이 → 포인트 클라우드(매트 안 픽셀만)
M4 패치 변형     초상 SparseFitter 의 3D TPS(r³, σ 8 cm) 를 76점 전체로 → 패치 1,220 초기 형상
M5 깊이 당김     SilhouetteFitter 를 **패치에도** 적용(법선 방향 ≤ 6 mm, λ ×3, 눈·입 제외 영역 동일) — 의사 깊이라 보수적으로
M6 이후 F2 → F3 → F5 → F6 → F8 → F9 공통(F4 는 M5 가 대신, F7 은 눈 감기·입 벌림 컷이 있으면 76점 차이로 eyeBlink·jawOpen 진폭만 보정)
```

- C 등급(1장)은 M1–M5 를 정면 1컷으로만, 좌우 대칭 100 %, 귀·뒤통수는 템플릿 그대로. 품질 카드에 "사진 1장 — 옆모습은 추정" 표시.
- 단안 경로 합격선: 76점 재투영 RMS < 2.0 px(1080p 기준), 의사 깊이 정합 잔차 중앙값 < 4 mm, 자기교차 0. **치수는 검증하지 않는다**(알 수 없다).

> **구현 노트(C4, 2026-10-05)** — M1–M6 는 **이미 동작한다**. C0 에서 초상의 `SparseFitter`(+ `SparseFaceGeometry`)를 포팅했을 때 이 경로 전체가 같이 들어왔고, `FaceFitter.fit` 이 `bundle.meta.sparse` 면 자동으로 그쪽으로 보낸다(T-401) — 위 서술과 수학은 다르지만 역할은 같다:
> - **M1**: 대응은 76점 전체가 아니라 `SparseFaceGeometry.keyPoints`(눈꼬리 4·코끝·입꼬리 2·턱, 8점) + `template.json visionIndices`(비어 있으면 0점 추가). `VisionCorrespondence`(76점 전체를 눈/입 루프에 호 길이로 대응)는 **아직 안 만들었다** — 8점만으로 이미 아래 합격선을 만족해서 당장 막힌 일이 없다. 더 조밀한 대응은 품질을 올리는 선택적 다음 단계로 남긴다(T-304).
> - **M2–M4**: "2변수 최소제곱 의사 깊이 + TPS" 대신 **여러 컷의 랜드마크 광선을 3×3 최소제곱으로 삼각측량**(`SparseFitter.correspondences`/`fit`) + **3D 바이하모닉 RBF** 로 두상 전체에 전파. Depth Anything 같은 ML 모델이 전혀 없어도 **컷이 2장 이상이면** 실제 깊이가 복원된다(합성 테스트: 코 깊이 오차 0.37 mm, 정면 단일 컷만 쓰면 9.28 mm).
> - **M5(깊이 당김)**: 광선 삼각측량 자체가 이미 "그 방향으로만 당긴다"는 보수적 제약이라(사전항 `triangulationPrior` 가 컷이 적을 때 템플릿 쪽으로 당김) 별도 `SilhouetteFitter` 패치 적용 단계가 필요 없어졌다.
> - **중요한 예외 — C 등급(사진 1장)**: 광선이 랜드마크당 1개뿐이라 삼각측량이 안 되고, 그 방향의 깊이는 템플릿 값을 그대로 쓴다(측면 형태는 못 고친다). **T-305(`MonoDepthEstimator`, Depth Anything V2)가 실제로 값어치가 있는 지점이 바로 여기**다 — B 등급(다컷)은 이미 삼각측량으로 잘 되니 T-305 가 급하지 않고, C 등급 단일 사진 품질을 올리고 싶을 때 다시 본다.
> - T-402 합격선은 `SparseCaptureTests`·`FitTests`(`sparseFit`·`sparseFitMultiShot`)로 이미 확인됨(§ `Docs/Tasks.md` C4). T-403(🧪 실기기)만 남았다.

### 6.5 텍스처 (`CoursonaTexture`)

- 초상 18·19차 `TextureBuilder` 그대로(가시성·투영·접합·탈조명·채움·영역 정리, Metal/CPU 패리티 0.000/255).
- 프리셋 `faceOnly`: `uvRegions.face`·`lid_L/R`·`lip` + **캡 UV 섬** 2k 기본(4k 선택). 나머지 영역은 스플랫 색 추출용 512² 한 장.
- 가시성: A 등급은 캡처 깊이(±15 mm) + 자기 가림, B·C 등급은 **인물 매트 + 자기 가림 + 의사 깊이 ±25 mm**(느슨).
- **눈 캡 텍스처**: 정면 중립 컷(눈 뜸)의 눈 윤곽 안쪽 픽셀을 캡 UV 로 투영. Vision 동공점(B) 또는 눈 루프 중심(A, 각막 가정)을 캡 UV 중심에 맞춘다 → 시선 UV 이동의 원점. 흰자·홍채 경계는 손대지 않는다(정체성 보존). 눈꺼풀 띠는 초상 규칙대로 피부색.
- **입 캡 텍스처**: 입 벌림 컷이 있으면 안쪽 입술 사이 픽셀(치아·혀)을 포켓 안쪽 벽 UV 로 투영, 없으면 어두운 입안 기본색(피부 명도의 25 %) + 템플릿 `textures` 의 치아 띠(있으면)로 윗벽만. 미소 컷은 입 UV 반경 0.12, 눈 감기 컷은 눈 UV 반경 0.08 제외.
- 탈조명·접합·피부 필터는 초상 그대로. B 등급은 ARKit 조명이 없으므로 조명 방향은 **얼굴에서 추정**(초상 T-404 이미 그렇게 함).

> **구현 노트(C5, T-501 선행, 2026-10-06)** — "캡 UV 섬" 을 어디에 둘지 정리했다. 처음엔 기존 `uvRegions.lid_L/lid_R/lip` 을 재사용하려 했지만, `Formats.md` 계약을 다시 보니 그 키들은 **눈꺼풀·입술 피부**(바깥에서 보이는 살) 영역이라 용도가 다르다 — 재사용하면 캡이 주변 피부 텍셀을 그대로 베끼는, 지금과 같은 문제가 재발한다. 그래서 `cap_eye_L`/`cap_eye_R`/`cap_mouth` 라는 **새 키**를 만들고 `CapBuilder` 가 그 사각형 안에 원형(중심-방사 각도) UV 섬을 만들도록 했다(`CapBuilder.close(loop:pocket:uvIsland:)`). 키가 없으면(지금의 실제 블렌더 내보내기 전부, 그리고 합성 템플릿도 기본은 없음) 옛 동작(바깥 고리 UV 상속)으로 조용히 되돌아간다 — 아무것도 깨지지 않는다.
> UV 매개변수화는 "루프를 도는 순서 i → 섬 안의 각도 i/n·2π" 로 단순하게 잡았다. 절대 방향(섬 안에서 어느 쪽이 "위") 은 안 맞을 수 있지만, T-502(실제 내용 투영) 는 3D 위치를 각 컷의 카메라로 다시 투영해 샘플링하는 방식이라(다른 모든 영역과 같은 일반 파이프라인) 이 섬의 절대 회전은 결과에 영향이 없다 — 인접한 루프 정점이 인접한 UV 를 받는다는 것만 중요하고, 그건 이 매개변수화로 보장된다.
> **아직 안 한 것**: (1) `TextureBuilder` 자체의 `faceOnly` 옵션(지금은 UV 전체를 늘 풀 해상도로 처리 — 얼굴+캡 섬만 2k/4k, 나머지는 512² 한 장으로 줄이는 최적화는 미구현) (2) ~~T-502~~(아래에서 완료) (3) **실제 블렌더 UV 언랩에 이 세 키를 위한 자리 비우기** — 지금까지 전부 `SyntheticTemplate`(테스트용 합성 템플릿) 에서만 검증했다. (3)은 사용자가 Blender+Claude Desktop MCP 로 작업할 의향이 있다고 한 것과 맞아떨어지는 첫 구체적인 요청사항이 될 수 있다 — C5 가 더 진행되어 정확한 크기·위치 요구사항이 정해지면 정리해서 전달한다.
>
> **구현 노트(C5, T-502, 2026-10-06)** — 눈·입 캡 내용물 투영에 **전용 코드가 필요 없었다**. `TextureBuilder.build`/`probe` 의 1단계(기하)에서 `BustEntity.init` 과 똑같은 패턴(피팅된 좌표 대입 → `CapBuilder.addingCaps` → 그 결과로 렌더 메시 생성)을 그대로 적용했더니, 캡 삼각형도 2~4단계의 **일반** 다중 컷 카메라 투영·접합·채움 파이프라인을 다른 영역과 똑같이 받는다 — 캡이 3D 공간에서 실제 눈/입 열린 자리에 있으니, "눈 뜸" 컷 카메라로 보면 자연히 눈 내용물이, "입 벌림" 컷 카메라로 보면 입 내용물이 투영된다. T-501 의 캡 UV 섬이 있으면 그 섬에 쌓이고, 없으면(지금) 바깥 고리 UV 에 상속되어 쌓인다 — 섬이 없어도 "틀린" 게 아니라 "정밀하지 않을" 뿐이다.
> `CoursonaTexture` 가 `CoursonaFace` 에 새로 의존하게 됐다(순환 없음: Texture→Face→Fit→Core). 구멍 없는 `SyntheticTemplate` 으로는 캡이 전부 nil 이라 기존 118개 테스트가 전부 그대로 통과해 **회귀가 없음을 확인**했지만, 이건 동시에 "구멍이 실제로 있을 때 캡 UV 섬에 진짜 내용물이 들어가는지" 는 아직 전용 테스트로 확인 못 했다는 뜻이기도 하다 — `SyntheticTemplate` 자체에 구멍을 내는 건 다른 테스트 다수가 그 토폴로지(정점 수·블렌드셰이프 레이아웃)에 의존해 위험이 크다고 보고 보류했다. 실제 블렌더 템플릿이 생기면 `coursona-validate --texture` 로 눈으로 확인한다.
>
> **구현 노트(C5, T-501 — `faceOnly` 옵션, 2026-10-06)** — T-502 에서 캡이 일반 파이프라인을 타게 됐으니, "얼굴 패치·눈꺼풀/입술 안쪽·캡 섬만 전체 해상도로 보고 나머지는 건너뛴다" 는 `faceOnly` 도 **새 채움 코드 없이** 구현됐다: 3단계(전체 해상도 누적)에서 텍셀의 삼각형이 얼굴 쪽(`triPatch`/`triLidInner`/`triLipInner`/캡)이 아니면 다중 컷 샘플링 자체를 생략한다 — 그 텍셀은 "관측 없음" 으로 남고, **기존** 4단계 채움(두피 평균·목 피부색·어깨→목 대체)이 지금까지 해 온 그대로 메운다. 캡 삼각형은 `capResult.caps`(이미 1단계에서 캡을 닫을 때 나온 결과)의 `triangleIndexRange` 로 바로 식별했다 — `makeRenderMesh()` 가 삼각형 순서를 보존해서 원본 인덱스의 삼각형 번호가 렌더 메시에서도 그대로 유지되기 때문에 새로 분류할 필요가 없었다.
> 나머지(두피·목·어깨) 색은 `TextureBuildResult.splatColor`(기본 512², `TextureBuildOptions.faceOnlyPreset`)로 따로 낸다 — 접합 보정·페더링 없이 컷 가중 평균만 썼다(스플랫은 삼각형별 이산 점이라 텍스처처럼 이음매가 보이지 않는다, §6.6).
> **Metal 패리티**: Metal 커널은 이 건너뛰기 로직을 모른다. `faceOnly` 를 켜면 `preferMetal` 설정과 무관하게 CPU 로 강제한다 — 커널까지 맞추는 건 비용 대비 지금 급하지 않다고 보고 미뤘다(패리티가 깨진 채로 "되는 것처럼" 두는 것보다 정직하게 느린 CPU 경로를 쓰는 게 낫다).
> 단위 테스트 4개(`FaceOnlyTextureTests`): splatColor 유무·크기·내용물, 전체 모드 대비 관측↔채움 비율이 의도대로 역전되는지, **얼굴 영역 자체의 품질은 전체 모드와 거의 같은지**(= 얼굴까지 같이 건너뛰는 실수가 없는지)를 확인한다. 단계별 소요 시간 비교는 256² 합성 테스트에서는 측정 잡음(머신 부하에 따라 쉽게 2 배씩 흔들림)이 너무 커서 뺐다 — 실제 속도 이득은 2k/4k·🧪 실기기에서 재는 게 맞다(T-505).

### 6.6 스플랫 — 얼굴면 밖 입체감 (`CoursonaSplat`)

학습 없음, 바인딩 + 초기화만.

| 항목 | 결정 |
|---|---|
| 바인딩 | 피팅된 흉상의 얼굴면 밖 삼각형(≈ 20,700)에 삼각형 id · 무게중심 · 법선 오프셋. 삼각형당 1–3개(면적 비례, 두피 2겹), 외곽 루프 안쪽 2 링 포함. 총 ≤ 60k |
| 위치·크기·회전 | 무게중심 + 법선 × 1.5 mm, 스케일 (외접원 r × 0.9, 같은 값, 1/3), 회전 = 접평면 기저. 어깨·목 1.3배 |
| 색 | 관측: 512² 알베도 텍셀. 미관측: 두피 = 관측 두피 평균(초상 실기기 (95,76,56)), 목·귀 = 얼굴 피부 기준색, 어깨 = 템플릿 옷 평균. B·C 등급은 매트 안 픽셀만 관측으로 친다. SH 0차 |
| 불투명도 | 피부 0.95, 두피 바깥 겹 0.6, 외곽 2 링 1.0 |
| 변형 | v1 은 Head/Neck 뼈 강체만. 매 프레임 버퍼 갱신은 v1.1 |
| 렌더 | `GaussianSplatComponent(GaussianSplatResource(bufferResource))`, 인터리브 14 float(16 B 패딩), sRGB. 불투명 얼굴면과의 정렬·섞임은 실기기 확인 항목 |
| 폴백 | 시뮬레이터·실패: 고스트 파트 + 512 알베도, UI "스플랫: 폴백" |
| 파일 | `splats.bin`: magic `CSP1` · count · stride · bindingFlag · 데이터 · 바인딩 { tri, u, v, offset } |
| 수치 | 초기화 ≤ 2 s(iPhone 15 Pro), 60k + 얼굴면 60 fps(iPhone), Mac 90 fps |

**스파이크 S-1(SHARP, Mac 전용, 비제품)**: 같은 정면 사진으로 SHARP 3DGS(PLY) 를 만들어 흉상 공간에 정합(얼굴 76점 ↔ 스플랫 깊이)하고, 얼굴면 밖 영역의 시각 품질을 §6.6 결과와 **나란히 스크린샷**으로 비교한다. 결과는 `Docs/Spikes.md` 에 수치·그림만 남기고 코드는 `coursona-spike` 타깃(제품 번들 제외, 가중치 미커밋). 목적은 "자체 초기화가 어디까지 부족한가" 를 재는 것.

### 6.7 런타임 리그 (`CoursonaRig`)

- `BustEntity`: 파트 `[faceSkin, eyeCapL, eyeCapR, mouthCap, ghost?]`, 머티리얼 각각(`PhysicallyBasedMaterial`, 피부 roughness 0.55; 눈 캡 roughness 0.15 + clearcoat 0.6 으로 촉촉함; 입 캡 roughness 0.7). `LowLevelDeformation` 블렌딩은 전체 정점.
- **시선**: 눈 캡 머티리얼의 `textureCoordinateTransform.offset` 을 `eyeLook{In,Out,Up,Down}_{L,R}` 가중치로 이동(최대 ±0.08 UV ≈ 홍채 반지름의 절반). 기하는 움직이지 않으므로 뚫림이 없다. 자동 시선 미세 움직임(초상 FaceRig)은 같은 경로.
- **깜빡임·눈꺼풀**: 패치는 템플릿/사용자 델타, 띠는 F8 의 c 기준 회전 델타. 눈 캡 정점의 델타 = 0.
- **입**: 입술 패치·띠는 셰이프, 입 캡 포켓은 LipInner 평균 변위를 따라간다(F8). `jawOpen` 에 따라 포켓 바닥이 아래로 열린다.
- `Identity` v3: `regionDeltas[shape] = [(vertexIndex, Δ)]`(띠·캡), `caps: { eyeL, eyeR, mouth }`(정점·인덱스·UV, 캡은 템플릿 밖 정점이므로 Identity 가 소유). identity.bin v1·v2 읽기 호환, v3 블록 추가. `runtimeDeltas` 가 패치 → regionDeltas → 나머지 ×s 순으로 덮어쓴다.
- 눈알·입안 자식 엔티티·`jawPivot` 회전·`mouthInnerShapes` 는 **삭제**.

### 6.8 라이브 구동 (`CoursonaDrive`) — "페르소나처럼"

| 소스 | 플랫폼 | 출력 | 비고 |
|---|---|---|---|
| `ARKitFaceDriver` | iPhone·iPad(`isSupported`) | ARKit 52 + `faceTransform`(고개) | 초상 `FaceCaptureSession` 라이브 경로 재사용, 60 Hz |
| `VisionFaceDriver` | Mac 기본, iOS 폴백 | **12 셰이프**: `jawOpen`(안쪽 입술 간격/입 폭), `mouthSmile_L/R`(입꼬리 높이·폭), `mouthPucker`(입 폭 축소), `mouthFunnel`(안쪽 입술 타원율), `eyeBlink_L/R`(눈 종횡비, 중립 캘리브레이션 2 s), `browInnerUp`·`browDown_L/R`(눈썹–눈 거리), `eyeLook{In,Out}_{L,R}`·`eyeLook{Up,Down}`(동공 위치/눈 폭) + yaw·pitch·roll | 30 fps, 1€ 필터(min-cutoff 1.0, β 0.3), 첫 2 초 중립 자세·눈 크기 캘리브레이션 |
| `MicVisemeDriver` | 전부 | 비셈 → 입 셰이프 가산(초상 `HangulViseme`·`MicLevelMeter`) | Vision 이 입을 못 잡을 때(마스크·가림) 보완 |
| 합성 | `FaceRigSystem` | 클립 ⊕ 라이브(입·눈썹·눈 영역 치환) ⊕ 비셈 가산 ⊕ 자동 깜빡임(라이브에 깜빡임 없을 때) | 초상 §6.7 규칙 |

거울 화면: 왼쪽 카메라 미리보기(선택), 오른쪽 흉상. 지연 목표 < 120 ms. Mac 은 카메라 권한을 **거울·B 등급 캡처에서만** 요청한다.

### 6.9 패키지·전송·병합 (`CoursonaIO`)

- **`.coursona`**(zip, UTI `com.coulson.coursona.persona`, `.chosang` 도 연다):

| 파일 | 내용 | 초상 호환 |
|---|---|---|
| `manifest.json` | schema **2**: 초상 schema 1 필드 + `app`, `tier`("A"/"B"/"C"), `sourceDevice`, `faceSurface{groups, triangleCount, capTriangles}`, `quality.selfIntersections`, `splats{count, bound}`, `scaleKnown`(A 만 true) | 모르는 키 무시 |
| `identity.bin` | v3(regionDeltas·caps) | "v2 로 저장" 옵션(캡·띠 델타 버림) |
| `albedo.png` · `mask.png` | 얼굴 영역 2k(캡 섬 포함) | 동일 |
| `caps.json` | 캡 메타(눈 중심·반지름·UV 섬 위치·동공 UV 원점) | 초상 무시 |
| `splats.bin` | §6.6 | 초상 무시 |
| `thumb.png` | 정면 512 | 동일 |
| `capture/` (선택, 기본 ON) | 캡처 번들(등급 포함) | 동일 |

- 전송: 초상 `ChosangTransfer`(Bonjour + TLS PSK 6자리) 서비스명 `_coursona._tcp`, 세 플랫폼 양방향. AirDrop·파일 앱·`onOpenURL` 초상 13차 그대로.
- **열기(모든 플랫폼)**: 템플릿 id·버전·정점 수 검사 → Identity·캡·알베도·스플랫 **모두 복원**(초상 `loadPersona` 가 알베도를 복원하지 않던 점 수정).
- **병합(업그레이드)**: 같은 페르소나 항목에 B/C 결과가 있고 A 캡처가 새로 들어오면, A 로 전부 재빌드하되 사용자가 고른 **이름·머리카락 선택·탈조명 강도** 는 유지. 반대로 A → B 덮어쓰기는 경고.
- 내보내기(선택, Mac): USDZ = 얼굴면 메시(캡 포함, 피팅 정점·알베도) usdc + 자체 zip, 스플랫 PLY(SH0). 셰이프키 포함은 v1.1.

### 6.10 Apple 제공 온디바이스 기술 채택표

| 기술 | 용도 | 플랫폼 | 상태 |
|---|---|---|---|
| ARKit `ARFaceTrackingConfiguration` | A 등급 캡처(1,220 정점·52·깊이·조명), 라이브 52 | iOS·iPadOS | 초상 검증 완료 |
| Vision `DetectFaceLandmarksRequest`(76) · `FaceObservation` 자세 | B·C 캡처, Mac 라이브 구동 | 전부 | 초상 T-205 검증(Mac 30 fps) |
| Vision `GeneratePersonSegmentationRequest` | B·C 실루엣 매트(가시성·스플랫 관측 영역) | 전부 | 신규 |
| Vision `VNDetectFaceCaptureQualityRequest` | B·C 컷 선택·게이트 | 전부 | 신규 |
| Core ML **Depth Anything V2 small**(Apple 배포, Apache-2.0) | B·C 의사 깊이 | 전부(ANE) | 신규, 번들 동봉 |
| FoundationModels(`Attachment` 이미지 + `@Generable`) | 외형 힌트(머리·안경·수염·옷, 초상 `AppearanceHints` 이식), 품질 카드 한 줄 설명·재촬영 안내 문장 생성(8 s 타임아웃, 실패 시 고정 문구) | OS 27(없으면 휴리스틱) | 초상 이식 + 확장 |
| RealityKit `LowLevelMesh`·`LowLevelDeformation` | 흉상 변형 | 기기·Mac(시뮬 CPU) | 초상 검증 완료 |
| RealityKit `GaussianSplatComponent` | 얼굴면 밖 | 기기·Mac | 신규 |
| AVFoundation `AVDepthData.cameraCalibrationData` | A 깊이 보정 | iOS·iPadOS | 신규 |
| Network.framework(Bonjour·TLS PSK) | 전송 | 전부 | 초상 검증 완료 |
| **SHARP**(Apple ML Research, 비상업 라이선스) | 스파이크 S-1 비교만 | Mac(스파이크 타깃) | 제품 제외 |
| Image Playground · `ImagePresentationComponent.Spatial3DImage` | — | — | **채택 안 함**(양식화 / 결과 기하 접근 불가) |

## 7. 성능 예산

| 항목 | 예산 | 근거 |
|---|---|---|
| A 등급 캡처 → `.coursona` | iPhone 15 Pro 90 s, iPad Pro(M) 40 s | 피팅 0.3–0.4 s + 텍스처 2k 1–3 s + 스플랫 2 s + F2/F9 ≤ 5 s, 나머지는 열 여유 |
| B 등급 | Mac(M) 60 s, iPhone 90 s | 의사 깊이 3컷 × ≤ 0.2 s + 매트 + MonoFitter(TPS 76점 + PCG) ≤ 5 s |
| C 등급 | 30 s | 1컷 |
| 로드 → 첫 프레임 | iPhone 1.0 s, Mac 0.8 s | 템플릿 0.24–0.54 s + 스플랫 3.4 MB |
| 프레임 | 얼굴면 + 60k 스플랫 + 라이브 구동, iPhone 60 fps · Mac 90 fps | GPU 변형 0.09 ms, Vision 30 fps 는 백그라운드 큐 |
| 라이브 지연 | < 120 ms(카메라 → 흉상) | ARKit 60 Hz / Vision 30 Hz + 1€ 필터 |
| 메모리 | 알베도 2k 16 MB + 메시 6 MB + 스플랫 4 MB + Depth Anything 50 MB(사용 중만) | — |
| 패키지 | ≤ 15 MB(캡처 미동봉), ≤ 55 MB(동봉) | 초상 T-206 실측 |

## 8. 보안·프라이버시

온디바이스 전부. 캡처 번들은 Documents, 전송은 사용자가 시작하고 PSK 코드, 패키지에 원본 사진 없음(동봉 선택). ARKit 얼굴 데이터·Vision 얼굴 분석 고지(`NSCameraUsageDescription`), 생체 식별 아님. Core ML 모델은 로컬 추론만. FoundationModels 는 온디바이스 `SystemLanguageModel` 만 쓰고 **Private Cloud Compute 모델은 쓰지 않는다**. Mac 카메라 권한은 B 등급 캡처·거울에서만 요청.

## 9. 검증 전략

- **단위(Swift Testing)**: 초상 테스트 전부 통과(복사 직후 기준선) + ① `InnerBandBuilder` 템플릿 자기 일치 0.0 mm ② `CapBuilder` 가 템플릿 구멍을 닫아 **경계 모서리 0**(워터타이트 검사) ③ `EyeOpeningSolver` 합성 구 복원 < 0.3 mm ④ `SelfIntersectionCheck` 가 일부러 겹친 띠를 잡는지 ⑤ identity.bin v1/v2/v3 왕복·초상 v2 읽기 ⑥ `splats.bin` 왕복 ⑦ `VisionCorrespondence` 가 76점 전 영역에 대응을 만들고 재투영 < 1 px(템플릿 자기 투영) ⑧ `MonoFitter` 합성(템플릿을 가상 카메라로 렌더 + 합성 상대 깊이 + 매트)에서 패치 RMS < 2 mm ⑨ `VisionFaceDriver` 셰이프 매핑: 합성 랜드마크(입 벌림·미소·깜빡임)에서 기대 가중치 ±0.1.
- **합성 픽스처**: 초상 `Fixtures/synthetic-*.chosangcapture` 셀프 피팅 RMS < 0.2 mm 유지 + 자기교차 0. 눈 감기·입 벌림·B 등급 합성 컷을 `SyntheticCapture` 에 추가.
- **실기기 픽스처**(저장소 밖): A 2세트(iPhone 16·iPad Pro), B 2세트(MacBook Air FaceTime HD·Face ID 없는 iPad), C 2장. 등급별 합격선(§6.4).
- **렌더 스냅샷**: 정면·좌 30°·눈 감기·입 벌림·시선 좌 5장, 픽셀 차이 < 2 %. **세 플랫폼에서 같은 패키지 → 같은 5장**.
- **실기기 체크리스트**: A 7컷 자동 촬영, 자기교차 배지 0, 눈 감기에서 눈 캡 안 보임, 입 벌림에서 포켓 안쪽 보임, 시선 이동 자연스러움, Mac B 등급 5컷 → 빌드 → 거울에서 입·눈썹·깜빡임 반응, iPhone → Mac 전송 후 스냅샷 일치, iPad 가로 거치, B → A 병합.

## 10. 알려진 위험과 완화

| 위험 | 완화 |
|---|---|
| 눈 캡이 "사진 붙인 눈" 으로 보임(평면감) | 캡은 구면(눈알 곡률)이고 머티리얼에 clearcoat. 시선 UV 이동 + 깜빡임이 생동감을 준다. 실기기 비교 뒤 홍채 영역만 미세 범프(v1.1) |
| 입 포켓 안쪽이 어둡기만 함(치아 없음, B·C 등급·입 벌림 컷 생략 시) | 기본 어두운 입안색 + 윗벽 치아 띠(템플릿 텍스처가 있으면). 입 벌림 컷을 UX 에서 권장 |
| Depth Anything 상대 깊이의 얼굴 왜곡(코 과장·평탄화) | M3 에서 템플릿 사전값으로 2 변수만 맞추고 M5 당김을 6 mm·λ×3 으로 보수적으로. 패치의 눈·입 영역은 깊이 당김 제외 |
| B 등급 치수 불명(s = 1) | 품질 카드 `scaleKnown=false`, A 로 업그레이드 유도. 눈 간격 64 mm 가정 명시 |
| Vision 라이브 셰이프가 거칠다 | 1€ 필터 + 중립 캘리브레이션 + 마이크 비셈 보완. 12 종으로 제한(과욕 금지) |
| 띠 재생성 공식이 어떤 얼굴에서 자기교차 | F9 가 잡고 띠 상수를 0.5 mm 씩 조정, 최대 3회. 남으면 배지 |
| LidInner·LipInner ↔ 루프 순서 추론 실패 | 0.5 mm 임계, 실패 시 템플릿 오류 보고. 초상 쪽에 `innerBands` 제안(Q6) |
| 스플랫·불투명 얼굴면 깊이 섞임 | 외곽 2 링 스플랫 불투명 1.0, 실기기 확인 뒤 1 mm 뒤로 |
| `GaussianSplatComponent` iPhone 성능 | 60k → 30k 다운샘플, 폴백 고스트 |
| SHARP 라이선스 | 제품 번들·제품 코드에서 완전 분리(`coursona-spike` 타깃, 가중치 미커밋), 문서에 수치·그림만 |
| Core ML 모델 50 MB 번들 크기 | Q7: 번들 동봉 vs 첫 실행 다운로드(온디바이스 원칙상 동봉 선호) |
| 복사한 ChosangKit 이 초상과 갈라짐 | 의도된 것. 초상 버그 수정은 커밋 단위 수동 반영, `Docs/Upstream.md` |

## 11. 다음 단계(v1.1 / v2)

1. 스플랫 매 프레임 변형(Metal 커널) + 짧은 색·불투명도 학습(초상 M8 T-803).
2. **Mac 가상 카메라**(Camera Extension) 로 FaceTime·회의 앱에 페르소나 송출 — "페르소나처럼" 의 완성형.
3. 오디오 → 52 셰이프 Core ML(Apple 제공 모델이 생기면 교체).
4. visionOS 빌드(초상이 담당하거나 패키지 호환으로 열기만).
5. 홍채 범프·치아 라이브러리 텍스처 품질.

## 12. 마일스톤 개요 (상세는 `Docs/Tasks.md`)

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| C0 셋업 | 프로젝트 `Coursona`(iOS·iPadOS·macOS), `CoursonaKit` 복사·리네임, 템플릿 반입(EyesMouth 제외), 초상 테스트 통과, 등급 판정 | 4개 빌드 + `swift test` 녹색 |
| C1 한 메시·투명 | `FaceSurfacePartition`, `CapBuilder`(템플릿 값), 파트 5개 렌더, 고스트 토글, 캡 UV 섬 | 시뮬·Mac 에서 구멍 없는 얼굴면만 보이는 흉상 |
| C2 얼굴면 완성(A) | F2·F4·F5·F6·F8·F9, identity v3, CLI 지표 | 합성 자기교차 0, 실기기 A 번들 자기교차 0 |
| C3 캡처 A/B/C | 7컷(A), Vision 5컷 + 매트 + 품질(B), 사진(C), `CoursonaML` Depth Anything, iPad 방향 | 세 등급 번들 저장 |
| C4 단안 피팅 | `VisionCorrespondence`·`MonoFitter` M1–M6, F7 단안 보정 | B 합성 RMS < 2 mm, Mac 실기기 빌드 |
| C5 텍스처·스플랫 | faceOnly + 캡 텍스처 + B 가시성, `CoursonaSplat`, 폴백 | iPhone 60 fps, 초기화 ≤ 2 s |
| C6 라이브 구동 | `CoursonaDrive` 3 소스, 거울 화면, 시선 UV | Mac 거울에서 입·눈썹·깜빡임, 지연 < 120 ms |
| C7 패키지·병합·플랫폼 동일성 | `.coursona` schema 2, 전송, 열기(전체 복원), 병합, 스냅샷 5장 3 플랫폼 일치 | 체크리스트 |
| C8 검수·마감 | 검수 화면, 품질 카드(FoundationModels 문장), 스냅샷 회귀, (선택) 내보내기 | 실기기 체크리스트 전항 |
| S-1 스파이크 | SHARP Mac 비교(제품 외) | `Docs/Spikes.md` 수치·그림 |

## 13. UX 에 넘기는 기능 목록 (디자인 PRD 의 입력)

1. **등급 판정·안내** — 막지 않는다. "Face ID 카메라로 가장 정확하게 / 이 기기 카메라로 만들기(치수 추정) / 사진 1장으로 만들기" 세 진입점과 각 등급의 기대 품질 설명.
2. **캡처 가이드** — A 7컷(필수 5 + 선택 2), B 5+2컷(Vision 자세 링·품질 점수 배너·배경 분리 미리보기), C 사진 선택 + 적합성 검사(정면·눈 뜸·입 다묾). 선택 컷 건너뛰기 시 "눈·입 정밀도 기본" 안내.
3. **빌드 진행** — 4단계 진행률, 등급별 예상 시간, 취소.
4. **검수** — 턴테이블, **자기교차 배지(0 / N)**, 포즈 토글(중립·미소·눈 감기·입 벌림·시선), 투명도/스플랫 토글, 품질 카드(등급·패치 RMS·자기교차·치수 알림·관측 비율·시간 + 한 줄 설명), 재촬영 유도(어느 컷인지).
5. **거울(라이브)** — 카메라 미리보기(선택) + 흉상, 구동 소스 표시(ARKit/Vision/마이크), 캘리브레이션 2 초 안내(Mac).
6. **저장·보내기** — 이름, 캡처 동봉 토글, `.coursona` 저장, 다른 기기로 보내기(6자리 코드), 공유 시트.
7. **라이브러리·병합** — 목록(썸네일·날짜·기기·등급 배지), 이름 변경·삭제·재빌드, "Face ID 기기에서 정밀하게 다시 만들기" 업그레이드 흐름.
8. **Mac** — 1·2(B)·3·4·5·6·7 전부 가능. 받기 화면(코드)·열기(`.coursona`/`.chosang`)·(선택) 내보내기.

## 14. 미결 사항 (사용자 결정 필요)

| # | 질문 | 기본값(답 없으면) |
|---|---|---|
| Q1 | 선택 2컷(눈 감기·입 벌림)을 넣을지 | 넣는다(선택, 건너뛰기 가능) |
| Q2 | 얼굴면 밖 "투명" 을 완전 제외로 할지, 옅은 고스트를 기본으로 보여줄지 | 완전 제외, 고스트는 토글 |
| Q3 | 스플랫 짧은 학습을 v1 에 넣을지 | 안 넣는다(v1.1) |
| Q4 | 패키지 확장자 `.coursona` 신설 vs `.chosang` 유지 | `.coursona` + `.chosang` 열기 |
| Q5 | Mac 내보내기(USDZ/PLY)를 v1 에 넣을지 | 선택(C8 마지막) |
| Q6 | 초상 쪽에 `innerBands` 인덱스·구멍 닫기 를 블렌더 산출물에 넣어 달라고 제안할지 | 제안 문서만, 코르소나는 앱 캡으로 동작 |
| Q7 | Depth Anything V2 small(≈ 50 MB) 을 앱 번들에 동봉할지, 첫 실행 때 받을지 | 동봉(온디바이스 원칙, 오프라인 동작) |
| Q8 | 캡 UV 섬 위치: 템플릿 아틀라스 여백 사용 vs 캡 전용 작은 텍스처 2장 | 아틀라스 여백(머티리얼 수 최소), 여백 없으면 전용 텍스처 |
| Q9 | SHARP 스파이크 S-1 을 수행할지(가중치 다운로드·Mac 실행, 제품 외) | 수행(C5 전에, 하루 상한) |
| Q10 | Mac 라이브 구동 셰이프를 12 종으로 제한하는 데 동의하는지(눈썹·입·눈만) | 12 종 |
