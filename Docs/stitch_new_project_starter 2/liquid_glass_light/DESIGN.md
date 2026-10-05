---
name: Liquid Glass Light
colors:
  surface: '#f9f9ff'
  surface-dim: '#d3daef'
  surface-bright: '#f9f9ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f1f3ff'
  surface-container: '#e9edff'
  surface-container-high: '#e1e8fd'
  surface-container-highest: '#dce2f7'
  on-surface: '#141b2b'
  on-surface-variant: '#414755'
  inverse-surface: '#293040'
  inverse-on-surface: '#edf0ff'
  outline: '#717786'
  outline-variant: '#c1c6d7'
  surface-tint: '#005bc1'
  primary: '#0058bc'
  on-primary: '#ffffff'
  primary-container: '#0070eb'
  on-primary-container: '#fefcff'
  inverse-primary: '#adc6ff'
  secondary: '#4c4aca'
  on-secondary: '#ffffff'
  secondary-container: '#6664e4'
  on-secondary-container: '#fffbff'
  tertiary: '#006b27'
  on-tertiary: '#ffffff'
  tertiary-container: '#008733'
  on-tertiary-container: '#f7fff2'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#d8e2ff'
  primary-fixed-dim: '#adc6ff'
  on-primary-fixed: '#001a41'
  on-primary-fixed-variant: '#004493'
  secondary-fixed: '#e2dfff'
  secondary-fixed-dim: '#c2c1ff'
  on-secondary-fixed: '#0c006a'
  on-secondary-fixed-variant: '#3631b4'
  tertiary-fixed: '#72fe88'
  tertiary-fixed-dim: '#53e16f'
  on-tertiary-fixed: '#002107'
  on-tertiary-fixed-variant: '#00531c'
  background: '#f9f9ff'
  on-background: '#141b2b'
  surface-variant: '#dce2f7'
typography:
  display-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.03em
  display-lg-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 34px
    fontWeight: '700'
    lineHeight: 42px
    letterSpacing: -0.025em
  headline-xl:
    fontFamily: Plus Jakarta Sans
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-xl-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 26px
    fontWeight: '600'
    lineHeight: 34px
    letterSpacing: -0.015em
  headline-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.015em
  headline-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: -0.01em
  headline-sm:
    fontFamily: Plus Jakarta Sans
    fontSize: 17px
    fontWeight: '600'
    lineHeight: 24px
    letterSpacing: -0.005em
  body-lg:
    fontFamily: Inter
    fontSize: 17px
    fontWeight: '400'
    lineHeight: 26px
    letterSpacing: -0.005em
  body-md:
    fontFamily: Inter
    fontSize: 15px
    fontWeight: '400'
    lineHeight: 22px
    letterSpacing: 0em
  body-sm:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: '400'
    lineHeight: 18px
    letterSpacing: 0.005em
  label-md:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.01em
  label-sm:
    fontFamily: Inter
    fontSize: 11px
    fontWeight: '500'
    lineHeight: 14px
    letterSpacing: 0.02em
  mono-code:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '400'
    lineHeight: 18px
    letterSpacing: 0em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  gutter: 1rem
  gutter-desktop: 1.5rem
  margin: 1rem
  margin-tablet: 1.5rem
  margin-desktop: 2.5rem
  space-2xs: 0.125rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2rem
  space-2xl: 3rem
---

## Brand & Style

This design system translates the future-forward Apple Human Interface Guidelines into an ultra-refined, luminous light-mode interface. Designed for high-precision workspace tools, spatial interfaces, and creative platforms, it pairs optical clarity with structural restraint. 

The aesthetic is characterized by:
- **Liquid Glass Materials:** Multi-layered optical glass with variable backdrop-blur, subtle refraction simulations, and light-catching specular hairline borders.
- **Luminosity & Air:** Pure, radiant white and neutral foundations that allow content and data to breathe without sterile clinical coldness.
- **Precision Typography:** Modern geometric and humanist letterforms optimized for instant legibility, strict vertical alignment, and hierarchical pacing.
- **Physical Weight & Friction:** Micro-interactions that mirror tangible physical glass surfaces—light dissipation on interaction, soft compression on press states, and effortless momentum.

## Colors

The palette establishes an optical hierarchy governed by Apple system conventions, calibrated explicitly for bright light-mode environments.

### Surface System
- **Canvas Base:** `#F8F9FA` establishes a bright, low-chroma ambient foundation.
- **Primary Surface (Pure Glass):** `#FFFFFF` with `72%` to `88%` alpha blending over backdrop filters (`backdrop-filter: blur(24px) saturate(180%)`).
- **Elevated Floating Glass:** `#FFFFFF` at `92%` alpha, reserved for modal sheets, contextual inspectors, and popovers.
- **Specular Hairline Border:** `rgba(255, 255, 255, 0.85)` for top/inner highlights; `rgba(17, 24, 39, 0.08)` for structural boundaries.
- **Viewport Pedestal:** `#0F172A` to `#1E293B` dedicated solely to 3D viewports, canvas editors, or media previews to isolate ambient light scatter.

### Typography & Contrast (WCAG AAA/AA Compliant)
- **Label Primary:** `#111827` (Contrast ratio > 15:1 against surfaces) for primary headings, crucial data points, and active titles.
- **Label Secondary:** `#374151` (Contrast ratio > 7:1) for body copy, subheaders, and form field values.
- **Label Tertiary:** `#6B7280` (Contrast ratio > 4.5:1) for hints, disabled states, and metadata labels.

### Functional Accents
- **System Active (Primary):** `#007AFF` for interactive highlights, primary CTAs, active radio toggles, and selection bounds.
- **System Accent (Secondary):** `#5856D6` for elevated status indicators, tags, and spatial coordinates.
- **System Success (Tertiary):** `#34C759` for verified badges and non-destructive alerts.

## Typography

The typographic hierarchy is engineered around legibility, proportional balance, and native Apple platform familiarity.

- **Headlines (`Plus Jakarta Sans`):** Selected for its smooth, polished curvature and contemporary architectural geometry. Tight tracking values create solid headline locks for interface titles, section headers, and modal prompts.
- **Body & Controls (`Inter`):** Deployed for micro-copy, data tables, inspectors, and controls. The neutral grotesque proportions ensure zero visual distortion across variable screen densities.
- **Code & Values (`JetBrains Mono`):** Dedicated to spatial coordinate readouts, transforms, system code snippets, and dimensional parameters.
- **Vertical Alignment:** All line-height increments align with a 4px/8px baseline grid to eliminate pixel jitter in glass container wrappers.

## Layout & Spacing

The layout philosophy follows a multi-tiered structural grid inspired by macOS sidebar-content-inspector configurations and iOS adaptive split views.

- **Responsive Grid Model:**
  - **Desktop (>= 1200px):** 12-column adaptive layout. Outer margins are fixed to `2.5rem` (`40px`), with `1.5rem` (`24px`) gutters. Sidebars and tool palettes operate as floating or docked translucent panels with fixed structural widths (260px–320px).
  - **Tablet (768px – 1199px):** 8-column layout. Outer margins drop to `1.5rem` (`24px`), gutters remain `1rem` (`16px`). Inspectors collapse into slide-over sheets.
  - **Mobile (< 768px):** 4-column layout. Outer margins contract to `1rem` (`16px`), gutters lock at `1rem` (`16px`). Sidebars collapse into native sliding drawers or bottom sheet controls.
- **Spacing Rhythm:** Built exclusively upon an 8-point base rhythm, with 4-point micro-spacing used for dense UI (e.g., segmented controls, toolbar icon groupings, and dropdown menus).

## Elevation & Depth

Visual depth is achieved through optical materials rather than heavy dark shadows. The system uses a continuous light-refraction model:

1. **Backdrop Blur Layers:**
   - **Base Glass (Panels, Lists, Cards):** `backdrop-filter: blur(20px) saturate(180%)`; Surface: `rgba(255, 255, 255, 0.72)`.
   - **Elevated Glass (Sidebars, Toolbars, Floating Menus):** `backdrop-filter: blur(32px) saturate(190%)`; Surface: `rgba(255, 255, 255, 0.82)`.
   - **Modal Glass (Overlays, System Sheets):** `backdrop-filter: blur(48px) saturate(200%)`; Surface: `rgba(255, 255, 255, 0.92)`.

2. **Specular Hairline Borders:**
   - Instead of standard solid borders, every glass layer features an inner specular rim: `box-shadow: inset 0 1px 0.5px 0 rgba(255, 255, 255, 0.9), inset 0 -1px 0.5px 0 rgba(0, 0, 0, 0.03)`.
   - Structural boundary line: `1px solid rgba(17, 24, 39, 0.06)`.

3. **Ambient Shadow Diffusion:**
   - **Level 1 (Subtle Controls & Floating Cells):** `0 2px 8px -2px rgba(17, 24, 39, 0.04), 0 1px 2px 0 rgba(17, 24, 39, 0.02)`.
   - **Level 2 (Cards & Detached Bars):** `0 12px 24px -6px rgba(17, 24, 39, 0.06), 0 4px 8px -2px rgba(17, 24, 39, 0.03)`.
   - **Level 3 (Modal Sheets & Inspectors):** `0 24px 48px -12px rgba(17, 24, 39, 0.12), 0 8px 16px -4px rgba(17, 24, 39, 0.04)`.

## Shapes

The design system incorporates continuous curvature ("squircle" surfaces) native to Apple platforms, preventing sharp optical interruptions.

- **Base Radius (0.5rem / 8px):** Applied to inputs, small buttons, tags, status pills, and dropdown menu items.
- **Card & Cell Radius (1rem / 16px):** Applied to standard content cards, preview containers, and inspector tiles.
- **Container & Sheet Radius (1.5rem / 24px):** Applied to system modals, detached sidebars, elevated inspectors, and floating docks.
- **Full Radius (9999px):** Applied strictly to standard action pills, primary search bars, and circular icon triggers.

## Components

### Buttons
- **Primary:** Solid `#007AFF` fill, text `#FFFFFF`, rounded to `0.5rem` or full-pill depending on context. Active state shifts to `#0062CC` with a subtle `scale(0.98)` spring compression.
- **Secondary (Glass):** `rgba(255, 255, 255, 0.75)` surface with specular inner ring and `rgba(17, 24, 39, 0.06)` boundary. Text `#111827`. Hover state shifts surface opacity to `0.9`.
- **Tertiary / Ghost:** Transparent surface, text `#007AFF` or `#374151`. Hover yields a subtle `rgba(17, 24, 39, 0.04)` fill with a 150ms ease transition.

### Input Fields
- **Search & Text Input:** Background `rgba(0, 0, 0, 0.03)` with `inset 0 1px 2px rgba(0, 0, 0, 0.05)`, transitioning on focus to pure `#FFFFFF` with a `2px solid #007AFF` outer glow ring and glass backdrop blur. 
- **Height & Spacing:** Standard fields use a 36px or 40px height with `space-md` horizontal padding.

### Checkboxes & Radio Buttons
- **Checkboxes:** 18px rounded rectangle (radius `4px`), border `1.5px solid rgba(17, 24, 39, 0.2)`. On active selection: `#007AFF` fill with a crisp white centered check icon.
- **Radio Buttons:** 18px concentric circle. On active: `#007AFF` ring with a 6px white center pip.

### Chips & Badges
- **Status Pills:** Compact layout with `space-xs` vertical and `space-sm` horizontal padding. Surface uses tinted glass (e.g., `#007AFF` at `10%` opacity with `#007AFF` text).
- **Interactive Filter Chips:** Radius `9999px`, background `rgba(255, 255, 255, 0.6)`. Active state fills solid `#111827` with `#FFFFFF` text.

### Cards & Content Containers
- Structural glass enclosure: `rgba(255, 255, 255, 0.75)` background, `24px` blur, Level 1 shadow, and specular hairline border.
- Internal padding matches `space-lg` (`24px`). Hoverable cards trigger a gentle elevation transition to Level 2 shadow with an additional `1%` opacity lift.

### 3D Viewport Pedestals & Toolbars
- **Viewport Frame:** Dark neutral boundary (`#0F172A`) providing maximum luminescence contrast for 3D spatial models.
- **Detached Canvas Toolbars:** Centered floating pill containers directly overlaying the pedestal with `backdrop-filter: blur(32px)`, surface `rgba(255, 255, 255, 0.8)`, and high-contrast `#111827` iconography.