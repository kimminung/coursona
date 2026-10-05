---
name: Liquid Stage
colors:
  surface: '#111318'
  surface-dim: '#111318'
  surface-bright: '#37393f'
  surface-container-lowest: '#0c0e13'
  surface-container-low: '#1a1b21'
  surface-container: '#1e1f25'
  surface-container-high: '#282a2f'
  surface-container-highest: '#33353a'
  on-surface: '#e2e2e9'
  on-surface-variant: '#c1c6d7'
  inverse-surface: '#e2e2e9'
  inverse-on-surface: '#2e3036'
  outline: '#8b90a0'
  outline-variant: '#414755'
  surface-tint: '#adc6ff'
  primary: '#adc6ff'
  on-primary: '#002e69'
  primary-container: '#4b8eff'
  on-primary-container: '#00285c'
  inverse-primary: '#005bc1'
  secondary: '#53e16f'
  on-secondary: '#003911'
  secondary-container: '#05b046'
  on-secondary-container: '#003a11'
  tertiary: '#ffb868'
  on-tertiary: '#482900'
  tertiary-container: '#ce7f00'
  on-tertiary-container: '#3f2300'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#d8e2ff'
  primary-fixed-dim: '#adc6ff'
  on-primary-fixed: '#001a41'
  on-primary-fixed-variant: '#004493'
  secondary-fixed: '#72fe88'
  secondary-fixed-dim: '#53e16f'
  on-secondary-fixed: '#002107'
  on-secondary-fixed-variant: '#00531c'
  tertiary-fixed: '#ffddbb'
  tertiary-fixed-dim: '#ffb868'
  on-tertiary-fixed: '#2b1700'
  on-tertiary-fixed-variant: '#673d00'
  background: '#111318'
  on-background: '#e2e2e9'
  surface-variant: '#33353a'
  stage-deep: '#0B0D12'
  stage-surface: '#14171F'
  stage-elevated: '#1C202B'
  glass-fill: rgba(255, 255, 255, 0.08)
  glass-fill-active: rgba(255, 255, 255, 0.16)
  glass-border: rgba(255, 255, 255, 0.18)
  glass-specular: rgba(255, 255, 255, 0.32)
  system-red: '#FF453A'
  tier-a-badge: '#007AFF'
  tier-b-badge: '#32ADE6'
  tier-c-badge: '#8E8E93'
  observed-scalp-fallback: '#5F4C38'
typography:
  display-lg:
    fontFamily: SF Pro
    fontSize: 34px
    fontWeight: '700'
    lineHeight: 41px
  display-lg-mobile:
    fontFamily: SF Pro
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 34px
  headline-lg:
    fontFamily: Apple SD Gothic Neo
    fontSize: 24px
    fontWeight: '700'
    lineHeight: 30px
  headline-md:
    fontFamily: Apple SD Gothic Neo
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 25px
  headline-sm:
    fontFamily: Apple SD Gothic Neo
    fontSize: 17px
    fontWeight: '600'
    lineHeight: 22px
  body-lg:
    fontFamily: Apple SD Gothic Neo
    fontSize: 17px
    fontWeight: '400'
    lineHeight: 22px
  body-md:
    fontFamily: Apple SD Gothic Neo
    fontSize: 15px
    fontWeight: '400'
    lineHeight: 20px
  body-sm:
    fontFamily: Apple SD Gothic Neo
    fontSize: 13px
    fontWeight: '400'
    lineHeight: 18px
  label-lg:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: '600'
    lineHeight: 20px
  label-md:
    fontFamily: SF Pro
    fontSize: 13px
    fontWeight: '500'
    lineHeight: 16px
  label-sm:
    fontFamily: SF Pro
    fontSize: 11px
    fontWeight: '500'
    lineHeight: 13px
  mono-pin:
    fontFamily: SF Pro
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 38px
    letterSpacing: 4px
rounded:
  sm: 0.5rem
  DEFAULT: 1rem
  md: 1.5rem
  lg: 2rem
  xl: 3rem
  full: 9999px
spacing:
  gutter: 1rem
  gutter-tablet: 1.5rem
  gutter-desktop: 1.5rem
  margin: 1rem
  margin-tablet: 1.5rem
  margin-desktop: 2rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 0.75rem
  space-lg: 1rem
  space-xl: 1.5rem
  space-2xl: 2rem
  space-3xl: 3rem
---

## Brand & Style

The design system embodies the Apple HIG Liquid Glass aesthetic calibrated specifically for real-time 3D spatial capture and mirrored persona rendering. It is honest, calm, and grounded in spatial precision. Rather than masquerading algorithmic reconstruction behind decorative metaphors, the interface establishes absolute trust through quiet material restraint, deep dark-neutral stages, and pristine visual feedback.

The target audience encompasses multi-device Apple users (iPhone, iPad, and Mac) ranging from everyday individuals creating an on-device personal avatar to spatial communication practitioners. The UI evokes technological serenity: the feeling of looking into a clean, unblemished digital mirror where private biometric processing occurs entirely on-device without cloud interference.

Visual architecture blends Liquid Glass with Dark Minimalist Spatial Staging:
- **3D Viewport as Hero:** The deep stage (#0B0D12 to #14171F) hosts the photoreal face surface and diffuse volumetric cloud ("입체감") without visual clutter or heavy frames.
- **Liquid Glass Materials:** Translucent frosted pills and floating toolbars leverage backdrop blurs, delicate 0.5px specular perimeter highlights, and subtle multi-layer elevation that recede when stationary and brighten under interaction.
- **Honest Linguistic Tone:** All Korean copy strictly rejects technical engineering jargon (RMS, RBF, ARKit, splats, manifold errors). Instead, the system converses with clear, polite, and reassuring real-world language: "Face ID 카메라", "이 기기 카메라", "크기 추정", "겹침 없음", and "입체감".

## Colors

The color palette centers on a pristine spatial dark stage paired with Apple system-native semantic accents. The default mode is dark to provide maximum contrast and immersion for 3D facial lighting, depth particles, and translucent frosted glass overlays.

- **Stage Neutral (`#0B0D12` & `#14171F`):** Establishes an infinite, non-distracting background depth for the persona bust. `#0B0D12` serves as the primary viewport void, while `#14171F` provides contextual depth in cards, sheets, and elevated stage controls.
- **System Blue (`#007AFF` - Primary):** Serves as the primary operational hue, driving affirmative actions, step completions, active segmented toggles, and Tier A (Face ID TrueDepth) verified indicators.
- **System Green (`#34C759` - Secondary):** Dedicated to verified geometric fidelity and pristine inspection states, notably the "겹침 없음 ✓" (no self-intersections) badge and calibration success indicators.
- **System Amber (`#FF9F0A` - Tertiary):** Communicates geometric estimation, warnings, and non-blocking advice, such as "크기 추정" (monocular scale estimation on Tier B/C) and lighting/pose threshold prompts ("조명이 어두워요").
- **System Red (`#FF453A`):** Reserved exclusively for hard errors, severe pose invalidation, and collision alerts ("겹침 2곳 — 다시 촬영 권장").
- **Observed Scalp Fallback (`#5F4C38`):** Preserved for unobserved vertex splat fills and perimeter blending when hair points fall outside the optical capture cone.

## Typography

Typography prioritizes system-native hierarchy, rapid cognitive processing during pose capture, and seamless multilingual harmony between Latin indicators and natural Korean phrasing.

- **Primary Typefaces:** Apple SD Gothic Neo handles Korean narrative, instructional banners, and status cards with calibrated letter spacing and comfortable body line heights. SF Pro powers numerical metrics, tier identifiers (A/B/C), system controls, and high-impact headlines.
- **Dynamic Type & Legibility:** All body and label styles scale dynamically. If an accessibility size is engaged, horizontal button bars and segmented pills wrap gracefully into vertical stacks without truncating vital guidance strings.
- **Numeric Clarity (`mono-pin`):** Device-to-device Bonjour transfer PINs and step timers utilize monospaced variant settings to eliminate horizontal jitter during live handshakes and build operations.
- **Korean Typographic Polish:** Punctuation is used sparingly in floating overlays. Micro-copy avoids rigid translations; line breaks use word-break keep-all styling to prevent awkward Korean syllable wrapping on compact viewports.

## Layout & Spacing

The spatial layout honors a 3D-first philosophy. The screen canvas acts as an unobstructed aperture into the spatial reconstruction. UI controls do not dock rigidly into opaque bars; they float as translucent Liquid Glass elements over safe-area peripheries.

- **Mobile (iPhone):** Single-column layout with fluid vertical flow. Top-anchored tracking chips and inspection badges sit beneath the dynamic island/sensor housing. Bottom-anchored glass pill bars stay pinned within thumb reach above the home indicator margin (16px lateral margin).
- **Tablet (iPad):** Adapts based on capture orientation. In landscape orientation, controls decouple from the vertical axis: capture chips move to a dedicated floating column along the left edge, action triggers float along the right margin, and the center 4:3 safe zone remains strictly clear for head orientation.
- **Desktop (macOS):** Employs an expansive 3-column unified workspace (minimum 1100×720 window). A collapsable glass sidebar (240px–280px) houses the persona library, a full-fidelity central viewport displays the bust, and an inspector glass panel (300px) docks on the right for inspection cards and blendshape diagnostics.
- **Safe Margins:** A minimum clearance of 24px (`space-xl`) is enforced between floating pill controls and the active head silhouette boundary.

## Elevation & Depth

Visual depth is achieved through optical translucency, multi-stage backdrop blurs, and specular light simulation rather than heavy drop shadows:

- **Level 0 (Stage Void):** The raw 3D viewport canvas rendered in `#0B0D12`. Zero blur, pure spatial rendering stage with soft floor contact shading.
- **Level 1 (Docked Containers & Sheets):** System bottom sheets and sidebar view panels. Background: `rgba(20, 23, 31, 0.85)` with a 30px system backdrop-filter blur and a 0.5px top border highlight (`rgba(255, 255, 255, 0.12)`).
- **Level 2 (Floating Glass Pills & Toolbars):** Active viewport controls (shutter triggers, pose segments, inspection badges). Background: `rgba(255, 255, 255, 0.08)` backed by a 24px blur, a subtle dual shadow (`0 4px 16px rgba(0, 0, 0, 0.35)` and `0 1px 2px rgba(0, 0, 0, 0.2)`), and an inner specular border highlight of 0.5px `rgba(255, 255, 255, 0.22)`.
- **Level 3 (Modal Alerts & Calibration Overlays):** Interactive dialogs and active calibration rings. Background: `rgba(28, 32, 43, 0.92)` with 40px blur, a focused elevation shadow (`0 12px 32px rgba(0, 0, 0, 0.55)`), and crisp specular rim illumination.

## Shapes

The design system embraces Level 3 (Pill-shaped) geometry, reflecting Apple's fluid, continuous corner radius language. 

- **Interactive Glass Pills:** Action buttons, segmented capture pills, floating badges, and status chips all utilize full capsule roundedness (continuous circular radii on short ends). This eliminates sharp structural vertices in the 2D UI, allowing the user's attention to focus on the curved contours of the 3D head mesh.
- **Sheets and Inspection Panels:** Bottom cards, sheets, and modal viewports use a continuous `rounded-xl` curve (24px to 32px corner radius) matching the hardware display curvature of modern iOS and iPadOS devices.
- **Segmented Trackers & Step Cards:** Internal nested items within modal cards feature an 8px to 12px squircle radius (`rounded-lg`), ensuring visual harmony with parent containers.

## Components

### 1. Floating Glass Pill Buttons
- **Style:** Capsule-shaped (`height: 48px` primary, `36px` compact). 
- **Surfaces:** Liquid glass translucent base (`glass-fill`) with 0.5px perimeter light stroke.
- **Primary Action (e.g., "거울로 보기", "만들기"):** Filled with solid `#007AFF` or tinted glass vibrant blue with crisp white SF Pro SemiBold typography.
- **Secondary Action (e.g., "저장", "건너뛰기"):** Ultra-thin translucent frosted glass (`rgba(255, 255, 255, 0.10)`) with label in neutral white.

### 2. Shot Chips Row (Capture Mode)
- **Structure:** Horizontal scroll or compact flex row housing 7 capture chips (정면, 왼쪽, 오른쪽, 위, 미소 + 선택: 눈 감기, 입 벌림).
- **States:**
  - *Pending:* Translucent outline chip, white muted text.
  - *Current Active:* Pulsing highlight stroke (`#007AFF`), bold label.
  - *Captured:* Replaces text with a circular 20px thumbnail preview alongside a subtle checkmark.
  - *Skipped (Optional):* Dimmed pill with "기본 정밀도" tag.

### 3. Orientation Angle Ring
- **Visuals:** Dotted ellipse floating at viewport center delineating acceptable pitch/yaw range (A: ±14°/±12°, B: ±12°/±10°).
- **Tracker:** Real-time solid reticle dot mapping current face direction.
- **Feedback:** Upon entering the gate, the ellipse border transitions from translucent white to `#007AFF`, triggering a circular 0.5s stroke progress fill accompanied by subtle ticking haptic feedback.

### 4. Quality & Inspection Badges
- **Style:** Compact capsule (`height: 28px`), docked top-center over 3D viewport.
- **No Overlap (Success):** Glass fill tinted with `#34C759` (15% opacity), stroke `#34C759`, label: "겹침 없음 ✓".
- **Intersection Warning:** Tinted with `#FF453A` (20% opacity), stroke `#FF453A`, label: "겹침 2곳 — 다시 촬영 권장".
- **Fidelity Status:** Secondary pill showing "Tier A", "이 기기 카메라 (크기 추정)", or "사진 1장 (옆모습 추정)".

### 5. Pose Segmented Control
- **Style:** Floating capsule bar containing five expression preview toggles: `중립` (Neutral), `미소` (Smile), `눈 감기` (Blink), `입 벌림` (Jaw Open), `시선` (Gaze).
- **Interaction:** Spring-animated glass thumb sliding beneath active segment with instantaneous GPU vertex reaction (<16ms).

### 6. Pull-Up Quality Card (Bottom Sheet)
- **Structure:** Expandable glass sheet docked at screen base.
- **Collapsed Summary:** Tier badge, "얼굴 정밀도 좋음", "관측 76%", "1분 12초", and button "자세히".
- **Expanded Detail:** Displays non-technical plain explanations generated on-device, followed by expandable diagnostics (mesh alignment RMS, observed vertex ratio, capture duration) hidden behind an intentional "상세 정보" disclosure disclosure.