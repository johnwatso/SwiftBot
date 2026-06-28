---
version: alpha
name: SwiftBot SwiftMesh
description: Native macOS design guidance for SwiftBot, using SwiftMesh as the forward-looking interface baseline.
colors:
  primary: "#F5F5F7"
  secondary: "#A1A1AA"
  tertiary: "#8E8E93"
  neutral: "#0B0B0D"
  surface: "#1C1C1E"
  surface-raised: "#242426"
  surface-muted: "#2C2C2E"
  stroke: "#3A3A3C"
  accent: "#005FB8"
  on-accent: "#FFFFFF"
  success: "#30D158"
  warning: "#FFD60A"
  attention: "#FF9F0A"
  danger: "#FF453A"
  info: "#64D2FF"
typography:
  title:
    fontFamily: SF Pro Display
    fontSize: 22px
    fontWeight: 600
    lineHeight: 28px
    letterSpacing: 0em
  section-title:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 600
    lineHeight: 18px
    letterSpacing: 0em
  body:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 400
    lineHeight: 18px
    letterSpacing: 0em
  caption:
    fontFamily: SF Pro Text
    fontSize: 11px
    fontWeight: 400
    lineHeight: 14px
    letterSpacing: 0em
  caption-strong:
    fontFamily: SF Pro Text
    fontSize: 11px
    fontWeight: 600
    lineHeight: 14px
    letterSpacing: 0em
  metric:
    fontFamily: SF Pro Text
    fontSize: 17px
    fontWeight: 600
    lineHeight: 22px
    letterSpacing: 0em
rounded:
  xs: 4px
  sm: 6px
  md: 8px
  lg: 10px
  xl: 12px
  xxl: 18px
spacing:
  xs: 4px
  sm: 6px
  md: 8px
  lg: 10px
  xl: 12px
  xxl: 16px
  section: 20px
components:
  app-background:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
  section-panel:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    rounded: "{rounded.xl}"
    padding: 12px
  metric-tile:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.primary}"
    typography: "{typography.metric}"
    rounded: "{rounded.md}"
    padding: 9px
  row-surface:
    backgroundColor: "{colors.surface-muted}"
    textColor: "{colors.primary}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: 8px
  status-pill:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.primary}"
    typography: "{typography.caption-strong}"
    rounded: "{rounded.xs}"
    padding: 6px
  metadata-label:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.secondary}"
    typography: "{typography.caption}"
    rounded: "{rounded.xs}"
    padding: 4px
  quiet-metadata:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.tertiary}"
    typography: "{typography.caption}"
    rounded: "{rounded.xs}"
    padding: 4px
  hairline:
    backgroundColor: "{colors.stroke}"
    textColor: "{colors.primary}"
    rounded: "{rounded.xs}"
    height: 1px
  primary-action:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    typography: "{typography.body}"
    rounded: "{rounded.xl}"
    padding: 12px
  topology-chip:
    backgroundColor: "{colors.surface-muted}"
    textColor: "{colors.primary}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: 9px
  connection-badge:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.caption}"
    rounded: "{rounded.xl}"
    padding: 7px
  status-success:
    backgroundColor: "{colors.success}"
    textColor: "{colors.neutral}"
    typography: "{typography.caption-strong}"
    rounded: "{rounded.xl}"
    padding: 6px
  status-warning:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.neutral}"
    typography: "{typography.caption-strong}"
    rounded: "{rounded.xl}"
    padding: 6px
  status-attention:
    backgroundColor: "{colors.attention}"
    textColor: "{colors.neutral}"
    typography: "{typography.caption-strong}"
    rounded: "{rounded.xl}"
    padding: 6px
  status-danger:
    backgroundColor: "{colors.danger}"
    textColor: "{colors.neutral}"
    typography: "{typography.caption-strong}"
    rounded: "{rounded.xl}"
    padding: 6px
  status-info:
    backgroundColor: "{colors.info}"
    textColor: "{colors.neutral}"
    typography: "{typography.caption-strong}"
    rounded: "{rounded.xl}"
    padding: 6px
---

## Overview

SwiftBot is a native macOS control surface for running a Discord bot. The preferred visual baseline is the SwiftMesh interface: calm, dense, operational, and distinctly Apple-platform-native.

The UI should feel like a modern macOS diagnostics panel rather than a marketing dashboard. It should help an operator scan status, spot trouble, and act with confidence. Use SwiftMesh as the styling reference for new app surfaces unless a more specific feature context says otherwise.

Core qualities:

- Native macOS first, with SwiftUI controls and Apple Human Interface Guidelines as the floor.
- Compact information density with clear hierarchy, not oversized web sections.
- Semantic color and iconography that explain runtime state.
- Low-contrast materials, quiet borders, and small depth cues.
- Direct, operational copy. Prefer labels like "Primary", "Failover", "Leader Term", and "Avg Latency" over promotional language.

## Colors

The color tokens describe the dark-mode visual baseline visible in SwiftMesh. In implementation, prefer SwiftUI semantic colors and materials so the interface adapts correctly to light mode, dark mode, vibrancy, accessibility contrast, and user accent settings.

- **Primary:** main text and important values. In SwiftUI, use `.primary`.
- **Secondary:** subtitles, metadata, icons, and less urgent labels. In SwiftUI, use `.secondary`.
- **Tertiary:** quiet dividers, timestamps, and extra metadata. In SwiftUI, use `.tertiary` when available.
- **Surface:** panel backgrounds. In SwiftUI, prefer `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`, or low-opacity `Color.primary` fills depending on the surrounding view.
- **Stroke:** hairline outlines. In SwiftUI, use `.white.opacity(0.10)` on material surfaces or `Color.primary.opacity(0.06...0.12)` on flat surfaces.
- **Accent:** primary commands and selected state. In SwiftUI, prefer `.accentColor`; the token uses a slightly deeper blue so static documentation examples maintain accessible contrast.
- **Success, warning, attention, danger, info:** runtime state colors. Use sparingly and pair with labels or SF Symbols so state is not communicated by color alone.

SwiftMesh often uses `Color.primary.opacity(0.02...0.12)` for nested surfaces. Keep that approach: subtle layers read better than saturated fills.

## Typography

Use system typography only. Do not introduce custom fonts.

Preferred SwiftUI styles:

- Screen title: `.title2.weight(.semibold)`
- Section title: `.headline.weight(.semibold)`
- Row title: `.subheadline.weight(.semibold)`
- Body and row metadata: `.subheadline`, `.caption`, `.caption2`
- Numeric metrics: `.headline.weight(.semibold).monospacedDigit()` or `.caption.monospacedDigit()`
- Logs, IDs, and machine output: `.caption.monospaced()` or `.system(.caption, design: .monospaced)`

Keep letter spacing at the system default. Avoid all-caps except compact role badges where the state must read as a label.

## Layout

Use System Settings and SwiftMesh-style dashboard structure:

- Scrollable vertical page with `VStack(alignment: .leading, spacing: 16...20)`.
- Page padding around `16...20pt`.
- Adaptive metric grids with minimum tile widths around `140...160pt`.
- Two-column diagnostic rows only when width supports them; collapse or stack on narrower contexts.
- Split-pane layouts for navigation-heavy surfaces and editor workflows.
- Fixed-size operational elements, such as topology chips and metric tiles, should have stable dimensions so live data does not shift the layout.

Avoid landing-page composition, hero sections, decorative card grids, web-style side gutters, custom scrollbars, and large empty promotional panels.

## Elevation & Depth

Depth is subtle:

- Prefer material backgrounds for major settings and preference cards.
- Prefer low-opacity fills for dashboard sections inside an already material-backed app shell.
- Use 1pt strokes to define edges.
- Use shadows rarely and lightly, such as `Color.black.opacity(0.03), radius: 2, y: 1` for SwiftMesh panels.
- Do not use decorative gradient orbs, bokeh, or ornamental glow effects for ordinary app screens.

The standard hierarchy is: app background, section panel, row or tile surface, status badge.

## Shapes

Use continuous rounded rectangles and capsules:

- Dense rows and topology chips: `8pt`
- Map and nested containers: `10pt`
- Section panels and alert panels: `12pt`
- Preference cards and broader glass surfaces: `18pt`
- Role badges and status pills: `Capsule`

Avoid very large radii on compact controls. The app should feel precise and native, not pillowy.

## Components

### Section Panels

Use `SwiftMeshSection` as the reference shape: icon plus title, 12pt padding, 10pt internal spacing, low-opacity fill, subtle stroke, and a tiny shadow. Sections group related operational data and should not contain another full card unless the nested element is a true repeated row, tile, map, or modal-like surface.

### Metric Tiles

Metric tiles should show a short label, a strong value, an SF Symbol, and a compact subtitle when useful. Values should use monospaced digits. Colors should mark state or category, but the label and subtitle must carry the meaning.

### Status Rows

Rows should be scannable: leading icon or status dot, primary label, secondary metadata, optional trailing metric. Keep vertical padding near 7...8pt and background opacity quiet.

### Topology Views

SwiftMesh topology views should stay diagrammatic and useful. Node chips, connection lines, latency badges, and health colors are appropriate. Keep node labels readable, avoid animation that competes with status, and ensure disconnected states remain visible but muted.

### Buttons

Use native SwiftUI button styles:

- `.borderedProminent` for primary destructive or operational commands after confirmation.
- `.bordered` for secondary commands.
- `.borderless` for inline icon utilities.
- Custom glass button styles only where the app already uses them, such as sticky save actions.

Buttons should use SF Symbols when the action benefits from immediate recognition.

## Do's and Don'ts

Do:

- Use SwiftMesh as the reference for app-wide dashboard and settings styling.
- Keep UI dense, native, and operational.
- Use SF Symbols for role, machine, connection, health, and action cues.
- Pair every status color with text or an icon.
- Use semantic SwiftUI colors and materials in code, even when DESIGN.md tokens provide static reference values.
- Keep copy factual and short.

Don't:

- Do not convert SwiftBot into a web-style UI or introduce external UI frameworks.
- Do not use hard-coded hex colors in SwiftUI unless there is a narrow, documented reason.
- Do not use decorative gradients, large hero blocks, or marketing copy inside the app.
- Do not communicate critical cluster state by color alone.
- Do not bury dangerous actions without confirmation.
- Do not let live metrics resize panels or push controls around.
