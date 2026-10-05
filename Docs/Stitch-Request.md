# Google Stitch 요청문 — 코르소나(Coursona)

> 작성일 2026-10-05. 첨부: `Docs/TechPRD.md`(v0.2), `Docs/UIUX-Prompt.md`.
> Stitch 특성에 맞춘 운용법: ① 프로젝트는 **Mobile(iPhone·iPad)** 과 **Web(Mac 데스크톱)** 둘로 나눈다 ② 첫 턴에 맥락 프롬프트 + 두 파일을 넣고 **화면 목록 확인**만 받는다 ③ 화면 생성은 **한 번에 6개 이하**로 끊는다 ④ 각 화면은 "이름 / 사용자 행동 / 레이아웃 / 핵심 요소 / 톤 / 제약" 틀로 쓴다 ⑤ 상태(오류·권한·폴백)는 후속 턴에서 다중 선택 후 한 프롬프트로 적용한다 ⑥ 3D 흉상은 Stitch 가 못 그리므로 **플레이스홀더 묘사**를 고정 문구로 넣는다.
> 프롬프트는 영어(모델 안정성), 화면 안 문구는 한국어로 지정한다. 아래 코드 블록을 그대로 붙여 넣는다.

---

## 0. 공통 플레이스홀더 문구 (모든 뷰포트 화면에 재사용)

```
3D viewport placeholder: a dark neutral stage showing a head-and-shoulders bust. Only the FACE SURFACE is rendered opaque and photoreal-ish (skin, eyelids, lips, a soft-edged face region ending just below the jaw and in front of the ears). The rest of the head, neck and shoulders is a soft translucent particle cloud ("입체감"), no visible mesh, no hard edges. No separate eyeballs or teeth objects. Subtle floor shadow. Leave generous empty margins; controls float over the stage in small glass pills.
```

---

## 1. Mobile 프로젝트 (iPhone 기본, iPad 변형은 후속 턴)

### 1-1. 첫 턴: 맥락 + 화면 목록 확인 (두 파일 첨부)

```
You are designing "Coursona" (코르소나), a native iOS 26 / iPadOS 26 app. Read the two attached documents first: TechPRD.md defines what is technically possible; UIUX-Prompt.md §3 lists facts the UI must respect and §5 lists the 8 screens in scope. Do not invent features outside UIUX-Prompt.md §5.

Product in one line: like Vision Pro's Persona, the user captures their own face and gets a 3D bust that follows their expressions, head and voice — on iPhone, iPad and Mac, fully on-device. Three input tiers: A = Face ID camera (best), B = regular camera (size estimated), C = one photo. The app never blocks a device; it only changes the tier.

Design system: Apple Human Interface Guidelines with the iOS 26 Liquid Glass look — system navigation bars, tab bars and sheets; small floating glass pills only for controls over the 3D viewport. Light and dark mode, Dynamic Type friendly, SF Symbols, SF Pro / Apple SD Gothic Neo. Calm, honest tone. All on-screen copy in Korean (한국어). Never show technical terms (no "TrueDepth", "ARKit", "RMS", "splat", "mesh"); use "Face ID 카메라", "이 기기 카메라", "입체감", "겹침 없음".

The 3D bust can't be rendered here, so wherever a viewport appears use this placeholder: [여기에 §0 플레이스홀더 문구 붙여넣기]

Do not generate screens yet. Reply with the list of the first 6 screens you will produce for iPhone (portrait), one line each with the primary user action, so I can confirm.
```

### 1-2. 둘째 턴: 1차 6화면 생성

```
Confirmed. Generate these 6 iPhone (portrait) screens, consistent as one app:

1) 시작·등급 안내 — user picks how to create. Layout: single column, hero illustration of the bust placeholder at top third, three large option cards below. Key elements: cards "Face ID 카메라로 만들기 (가장 정밀)", "이 기기 카메라로 만들기 (크기 추정)", "사진 1장으로 만들기", each with one-line expectation text and a small tier badge A/B/C; footer link "이미 만든 코르소나 열기". Tone: calm, welcoming. Constraints: no tech terms, large tap targets.

2) 캡처 가이드 (Face ID, A tier) — user holds a pose until auto-capture. Layout: full-screen camera preview (front camera, mirror OFF by default), overlays only. Key elements: top row of 7 shot chips (정면·왼쪽·오른쪽·위·미소 + 선택: 눈 감기·입 벌림) with thumbnails for done ones; center angle ring = dotted ellipse showing the allowed range with a dot for current head direction; a circular hold progress that fills over 0.5 s; bottom glass pill bar with 셔터, 건너뛰기 (only enabled on optional shots), ⓘ; top banner slot for warnings "조명이 어두워요" / "깊이 정보를 기다리는 중"; small toggle for 음성 안내 (default off). Tone: focused, minimal text. Constraints: controls must not cover the face.

3) 캡처 가이드 (이 기기 카메라, B tier) — same skeleton as screen 2, differences only: background-separation preview (person cut out, dim background), a quality score banner "선명도 좋아요 / 조금 더 밝게", and a persistent subtle badge "크기 추정" at top. Keep identical chip row and ring.

4) 빌드 진행 — user waits. Layout: viewport placeholder dimmed in background, centered card. Key elements: 4-step stepper 피팅 → 얼굴면 → 텍스처 → 입체감 with current step highlighted, overall progress bar, estimated time "약 1분 30초 남음", tier badge, 취소 button, hint text "화면을 꺼도 계속 진행돼요". Tone: reassuring.

5) 검수 — user inspects the result. Layout: viewport placeholder fills the screen; top-left back; top-right ⓘ; a quality badge pill at top center "겹침 없음 ✓" (alternate state: "겹침 2곳 — 다시 촬영 권장"); bottom: segmented pose toggle 중립·미소·눈 감기·입 벌림·시선, two small toggles 투명/입체감, primary button 거울로 보기, secondary 저장. Pull-up quality card sheet (collapsed state visible): tier badge, "얼굴 정밀도 좋음", "크기: 추정됨" (B/C only), "관측 76%", "1분 12초", one-sentence explanation, button "자세히". Tone: confident, uncluttered.

6) 거울 (live) — user sees the bust mimic them. Layout: viewport placeholder large; small picture-in-picture camera preview (toggleable) bottom-left; top pill showing the driving source "Face ID 표정 · 마이크"; bottom glass bar: 카메라 미리보기 toggle, 마이크 toggle, 저장/공유. Include a 2-second calibration overlay state as a variant ("정면을 보고 잠시 멈춰 주세요", circular countdown). Tone: playful but quiet.

Use the viewport placeholder described earlier for screens 4, 5, 6. Korean copy on everything.
```

### 1-3. 셋째 턴: 2차 6화면 생성

```
Generate 6 more iPhone screens in the same style:

7) 사진 1장으로 만들기 (C tier) — user picks a photo and gets a suitability check. Layout: photo picker entry card, then selected photo with face box overlay and a checklist: 정면 ✓ / 눈 뜸 ✓ / 입 다묾 ✓ / 밝기 △. Primary 만들기, secondary 다른 사진 선택. Note badge "옆모습은 추정됩니다".

8) 저장·보내기 — user names and saves. Layout: form sheet. Key elements: thumbnail of the bust, name field (default "내 코르소나"), toggle "촬영 원본 함께 저장" (default on) with one-line reason, primary 저장, after-save row of actions: 다른 기기로 보내기, AirDrop, 파일에 저장.

9) 다른 기기로 보내기 — user sends to a nearby device. Layout: list of discovered devices (device name, kind icon iPhone/iPad/Mac), selected device shows a 6-digit code entry "상대 기기에 표시된 6자리 코드", progress bar with size and ETA, states: 검색 중 / 코드 틀림 다시 입력 / 완료.

10) 라이브러리 — user manages personas. Layout: grid of cards (thumbnail, name, date, device icon, tier badge A/B/C). Swipe or ⋯ menu: 이름 변경, 다시 만들기, 삭제. Empty state: friendly illustration + "첫 코르소나를 만들어 보세요" with the three entry buttons. One card shows an "업그레이드 가능" ribbon.

11) 업그레이드 병합 — user re-captures on a Face ID device to improve a B/C persona. Layout: explainer card "Face ID 카메라로 더 정밀하게 다시 만들어요", shows what is kept (이름, 머리 모양 선택, 조명 설정) and what is replaced (얼굴 형태, 입체감), primary 다시 촬영, and a warning variant for the reverse direction "정밀한 버전을 덮어쓰게 돼요".

12) 권한·불가 상태 모음 — a single screen composed of 4 stacked cards showing: 카메라 권한 거부 (button 설정에서 허용), 마이크 꺼짐 (거울에서 입모양은 표정으로만), 로컬 네트워크 권한 (전송용), 저장 공간 부족. Each with icon, one-line reason, one action.
```

### 1-4. 후속 턴 (다중 선택 후 적용)

```
Apply to all selected screens: dark mode variant; keep Liquid Glass pills legible over the dark stage; verify contrast of Korean text ≥ 4.5:1.
```

```
Apply to all selected screens: Dynamic Type "Accessibility Large" variant — stack horizontal controls vertically if needed, never truncate the primary button label.
```

```
Create iPad (landscape) variants of screens 2, 5 and 6: the viewport stays centered with 4:3 safe area; move the shot chips to a left column and the control bar to the right edge; nothing may cover the face.
```

```
Connect a prototype flow: 1 → 2 → 4 → 5 → 6 → 8 → 9, and 1 → 7 → 4. Use the default push transition; sheets for 8 and 9.
```

---

## 2. Web 프로젝트 (Mac 데스크톱)

### 2-1. 첫 턴: 맥락 (두 파일 첨부, Mobile 과 같은 맥락 문단 재사용 후 아래 추가)

```
[1-1 의 맥락 문단을 그대로 붙인 뒤:]

This project is the macOS 26 version of the same app, designed as a desktop window (min 1100×720), not a website. Use macOS conventions: a left sidebar (library), a main content area (3D viewport), and a right inspector panel (quality / settings). Unified toolbar with Liquid Glass. The Mac can do everything except Face ID capture: it creates personas with its regular camera (tier B), opens .coursona / .chosang files, receives from iPhone/iPad with a 6-digit code, shows the mirror with camera-based expressions (2-second calibration), and exports from a menu only.

Do not generate yet. List the 6 desktop screens you will produce so I can confirm.
```

### 2-2. 둘째 턴: Mac 6화면 생성

```
Confirmed. Generate these 6 macOS desktop screens (1280×800), one consistent window chrome:

1) 메인 — library sidebar (persona list with thumbnail, name, tier badge, device), center viewport placeholder, right inspector with tabs 품질 / 설정: quality card (등급, 얼굴 정밀도, 겹침 없음, 크기: 추정됨, 관측 비율, 시간, 한 줄 설명, 자세히), toggles 투명/입체감, pose segmented control. Toolbar: 새로 만들기 ▾ (이 Mac 카메라로 / 사진 1장으로 / 받기…), 거울, 공유.

2) 받기 — modal sheet: large 6-digit code displayed for the sender, device name, "같은 Wi-Fi 에 있어야 해요", receiving progress state, done state with 열기 button.

3) 열기·불일치 — drag-and-drop zone for .coursona / .chosang over the viewport, plus an error sheet variant "이 파일은 다른 흉상 템플릿으로 만들어졌어요" with options 촬영 원본으로 다시 만들기 (enabled only if bundled) / 취소.

4) 캡처 (이 Mac 카메라, B tier) — full-window camera stage with person cut-out preview, 7 shot chips across the top, angle ring and hold progress in the center, quality banner, right-side vertical control bar (셔터, 건너뛰기, 음성 안내, ⓘ), persistent badge "크기 추정". Mirror preview OFF by default.

5) 거울 (Mac) — viewport placeholder large, PiP camera bottom-left, source pill "카메라 표정 · 마이크", calibration overlay variant "정면을 보고 2초만 멈춰 주세요" with countdown ring, and a "얼굴을 찾을 수 없어요" variant.

6) 빌드 진행 + 저장 — a sheet with the 4-step stepper (피팅 → 얼굴면 → 텍스처 → 입체감), ETA, 취소; followed by the save state: name field, "촬영 원본 함께 저장" toggle, 저장, then actions 다른 기기로 보내기 / 파일에 저장 / 내보내기… (내보내기 is a disclosure, not a primary button).
```

### 2-3. 후속 턴

```
Apply to all selected: dark mode variant with the same sidebar/inspector widths; ensure the viewport remains the visual focus.
```

```
Add a compact-window variant (1000×680) of screen 1 where the inspector collapses into a popover from a toolbar button.
```

---

## 3. 결과를 받은 뒤 할 일

1. Stitch 결과 화면을 `Docs/UX/stitch/` 에 PNG 로 저장하고, 화면 번호를 파일명에 넣는다(예: `m05-review-light.png`).
2. `UIUX-Prompt.md` §6 의 UXPRD.md 구조대로 상태표·문구표를 채울 때 이 화면들을 근거 그림으로 쓴다.
3. 테크PRD 와 충돌하는 요소(분리 눈알·치아, 서버·계정, 기술 용어 노출, B/C 등급 치수 정확도 암시)가 보이면 해당 화면만 다시 생성한다.
