---
name: Dispatch
description: Zero-overhead, keyboard-driven native macOS triage client for Gmail and GitHub
colors:
  primary: "#a855f7"
  primary-hover: "#9333ea"
  accent: "#007aff"
  gmail-red: "#ef4444"
  github-purple: "#a855f7"
  github-green: "#22c55e"
  star-yellow: "#eab308"
  warning-orange: "#f97316"
  surface-background: "#1e1e1e"
  surface-bar: "#252526"
  surface-secondary: "#2d2d2d"
  surface-border: "#3c3c3c"
  text-primary: "#ffffff"
  text-secondary: "#9ca3af"
  text-tertiary: "#6b7280"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif"
    fontSize: "44px"
    fontWeight: 300
    lineHeight: 1.1
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif"
    fontSize: "22px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.015em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "normal"
  label:
    fontFamily: "ui-monospace, Menlo, Monaco, 'SF Mono', monospace"
    fontSize: "11px"
    fontWeight: 600
    letterSpacing: "0.02em"
rounded:
  xs: "3px"
  sm: "4px"
  md: "6px"
  lg: "8px"
  xl: "10px"
  card: "12px"
  full: "9999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "24px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "#ffffff"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "6px 14px"
  button-primary-hover:
    backgroundColor: "{colors.primary-hover}"
    textColor: "#ffffff"
  button-subtle:
    backgroundColor: "transparent"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.md}"
    padding: "4px 8px"
  badge-unread:
    backgroundColor: "{colors.accent}"
    textColor: "#ffffff"
    rounded: "{rounded.full}"
    padding: "2px 7px"
  badge-pr:
    backgroundColor: "rgba(168, 85, 247, 0.15)"
    textColor: "{colors.github-purple}"
    rounded: "{rounded.xs}"
    padding: "1px 4px"
  sidebar-row-selected:
    backgroundColor: "rgba(0, 122, 255, 0.15)"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.md}"
    padding: "5px 8px"
  toast-banner:
    backgroundColor: "rgba(30, 30, 30, 0.85)"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.xl}"
    padding: "10px 16px"
---

# Design System: Dispatch

## Overview

**Creative North Star: "The Keyboard-Centric Cockpit"**

Dispatch is an uncompromising native macOS utility engineered for extreme developer responsiveness and zero latency. It strips away the ambient noise, electron container bloat, and visual excess of modern web software in favor of pure desktop utility. Operating as a calm, disciplined instrument panel, Dispatch enables rapid-fire triage across Gmail and GitHub with instantaneous sub-50ms feedback, low idle memory consumption (<50 MB), and ergonomic keyboard chords.

The aesthetic adheres strictly to macOS Human Interface Guidelines (HIG) while celebrating the precision of modern developer tools. Translucent vibrant materials (`.bar`, `.ultraThinMaterial`, `NSVisualEffectView`) integrate seamlessly into macOS Sonoma and Sequoia, creating an authentic desktop silhouette. Rich status signals—vibrant purple for GitHub Pull Requests and Agent actions, emerald green for issues and inbox-zero states, energetic red for Gmail mailboxes, and amber for alerts—stand out with razor-sharp clarity against subdued dark and light system backdrops.

**Key Characteristics:**
- **Authentic macOS Pedigree:** Employs native `NavigationSplitView` three-column layouts, system vibrancy materials, system SF Pro and SF Mono type hierarchies, and standard macOS control sizing.
- **Utilitarian & Keyboard-First:** Interfaces are designed around visible keyboard affordances and high-density information display without visual clutter.
- **Vibrant Status Semantics:** Color is applied with deliberate restraint to convey domain meaning (unread counts, PR vs Issue status, agent execution states).
- **Sub-50ms Density:** Compact row heights, crisp borders, and balanced whitespace provide maximum contextual awareness without cognitive fatigue.

## Colors

The color palette is derived directly from native macOS system roles combined with high-contrast semantic accents for developer workflow clarity.

### Primary
- **Agent Purple** (#a855f7): The signature action color for local AI coding agent dispatch (`Cmd+Shift+A`) and GitHub Pull Request workflows. Represents intelligent automation and power features.
- **Agent Purple Hover** (#9333ea): Darkened active state for primary action buttons.

### Secondary
- **System Accent Blue** (#007aff): macOS default selection indicator, active list item highlight backgrounds, and unread conversation markers.
- **Inbox Red** (#ef4444): Reserved strictly for Gmail iconography and critical connection alerts.
- **Terminal Green** (#22c55e): Signals GitHub issues, connected status badges, and the celebratory "Inbox Zero" empty state.
- **Attention Amber** (#f97316): Open Work stale warnings, rate-limiting notifications, and truncation banners.
- **Star Yellow** (#eab308): Triage item bookmarking and starred conversation flags.

### Neutral
- **Window Canvas** (#1e1e1e): The foundational background canvas adapting dynamically across dark and light macOS appearance.
- **Translucent Chrome** (#252526): Toolbars, headers, and status bars styled with native `.bar` vibrancy.
- **Surface Elevation** (#2d2d2d): Inset background for issue descriptions, comment cards, and card containers.
- **Hairline Border** (#3c3c3c): Subtle 1px structural dividing lines (12% to 18% opacity) providing razor-sharp spatial separation.
- **Text Primary** (#ffffff): Main titles, headers, and unread subject text with maximum legibility.
- **Text Secondary** (#9ca3af): Authors, relative timestamps, snippets, and secondary metadata.
- **Text Tertiary** (#6b7280): Keyboard hints, empty-state copy, and peripheral captions.

### Named Rules
**The Rarity of Red Rule.** Red (#ef4444) is exclusively reserved for the Gmail mailbox icon and catastrophic authentication errors. It is never used for ordinary dismissals or neutral status tags.

**The Semantic Sparkle Rule.** Purple (#a855f7) always signals GitHub Pull Requests or local AI Agent integration (`Cmd+Shift+A`). When the user sees purple, an agent or PR action is available.

## Typography

Dispatch leverages Apple's San Francisco system typeface family (`SF Pro Text`, `SF Pro Display`, and `SF Mono`), ensuring optimal hinting, optical sizing, and legibility at high desktop display densities.

**Display Font:** SF Pro Display (fallback: `-apple-system, BlinkMacSystemFont, sans-serif`)  
**Body Font:** SF Pro Text (fallback: `-apple-system, BlinkMacSystemFont, sans-serif`)  
**Label/Mono Font:** SF Mono (fallback: `ui-monospace, Menlo, Monaco, monospace`)

**Character:** Crisp, functional, and authoritative. Tabular figures and monospace accents maintain alignment across rapidly updating counts and timestamps.

### Hierarchy
- **Display** (Light 300, 44px, line-height 1.1): Empty-state hero glyphs and primary welcome headings.
- **Title** (Bold 700, 22px, line-height 1.25): Detail pane subject and issue header titles. Enables text selection.
- **Headline** (Semi-bold 600, 15px, line-height 1.3): Section headers, list view titles, and modal headers.
- **Body** (Regular 400 / Semi-bold 600, 13px, line-height 1.4): Primary stream rows, email author names, and markdown comment text. Unread rows transition weight from regular to semi-bold/bold.
- **Snippet** (Regular 400, 12px, line-height 1.35): Two-line email body and issue preview snippets.
- **Label / Monospace** (Semi-bold 600, 11px, letter-spacing 0.02em): Issue numbers (`#124`), git commit hashes, CLI agent terminal commands, and system status tags.

### Named Rules
**The Monospaced Identity Rule.** Issue identifiers (`#402`), keyboard shortcuts (`⌘⇧A`), and terminal command strings must always be rendered in `SF Mono` or with `.monospacedDigit()` to preserve column scanability.

## Layout

The window architecture is organized around a balanced three-column `NavigationSplitView`:

1. **Sidebar Navigation (Width: 200px min, 220px ideal, 280px max):**
   - Host for top-level workspace streams (`Gmail`, `GitHub`).
   - Sticky bottom status utility bar hosting settings and account status.
2. **Triage Stream (Width: 280px min, 320px ideal, 420px max):**
   - High-density virtualized list presenting unread items, badges, authors, relative time, and snippets.
   - Header with sticky filter summaries and rate-limit banners.
3. **Detail Inspector (Width: 400px min, 600px ideal, flexible max):**
   - Persistent detail viewing area with fixed header toolbar, action buttons, and isolated WKWebView or markdown timeline.

Spacing strictly adheres to a 4px modular grid:
- **Compact Spacing (4px, 8px):** Internal element spacing inside list rows, badge padding, and icon gaps.
- **Component Padding (10px, 12px, 14px):** Toolbar headers, banner insets, and card containers.
- **Structural Gutters (16px, 20px, 24px):** Window edge margins and modal sheets.

## Elevation & Depth

Dispatch uses native macOS tonal layering and window materials rather than simulated drop shadows. The canvas feels physically integrated into the operating system.

Depth is achieved through three primary tiers:
- **Base Canvas:** Window background (`NSColor.windowBackgroundColor`).
- **Translucent Vibrancy:** System `.bar` and `.ultraThinMaterial` on toolbars, sidebar rails, and headers.
- **Floating Overlays:** Detached floating toasts and undo banners use `.ultraThinMaterial` paired with a 1px white border stroke at 18% opacity and soft ambient diffusion (`box-shadow: 0 10px 24px rgba(0, 0, 0, 0.25)`).

### Shadow Vocabulary
- **Floating Toast / Banner** (`0 10px 24px rgba(0, 0, 0, 0.25)`): Elevates floating action confirmations and the 6-second undo toast above scrollable detail content.
- **Welcome Icon Glow** (`0 6px 12px rgba(0, 122, 255, 0.35)`): Ambient back-glow on onboarding brand marks.

### Named Rules
**The Flat-By-Default Rule.** Content surfaces, list rows, and detail panes remain completely flat at rest. Depth is reserved solely for floating transient overlays (toasts, undo bars, and popovers).

## Shapes

Dispatch adopts standard macOS continuous curvature (squircle geometry) for organic integration with window hardware:

- **Row Highlights (6px continuous):** Used for sidebar row selection and timeline comment bubbles.
- **Action Buttons & Cards (8px continuous):** Standard control buttons and description containers.
- **Floating Banners (10px continuous):** Toast notifications and undo prompts.
- **Pills & Status Capsules (Continuous Capsule / 4px):** Unread count badges, "PR" tags, and HTML email indicators.

## Components

### Action Buttons
- **Dispatch to Agent Button:** Primary focal control in GitHub detail. Tinted Agent Purple (`#a855f7`), bordered-prominent style, 8px radius, featuring the `sparkles` icon.
- **Secondary Tool Actions:** Borderless or bordered macOS control buttons (Archive `e`, Star `s`, Trash `#`, Open Web `⌘O`). Small control size (24px height).

### Stream List Rows
- **Triage Row:** 8px unread indicator dot, 24px circular author avatar (or two-letter fallback badge), two-line snippet clamp, and horizontal metadata stack.
- **Active Selection:** Accent-tinted background (`rgba(0, 122, 255, 0.12)`) without heavy outer borders.

### Badges & Status Pills
- **Unread Badge:** Capsule shape, accent blue fill with white bold text (`11px`).
- **PR Indicator:** 3px continuous corner radius, 15% purple background tint, 9px bold purple monospace text.
- **Workflow Pills:** 4px radius, 18% secondary tint, 10px medium label.

### Floating Undo & Toast Banner
- **Undo Banner:** Inset 16px from bottom window edge. Translucent ultra-thin material, 10px corner radius, 1px white outline (18% opacity), eye-slash icon, inline "Undo" button, and 6-second auto-dismissal.

## Do's and Don'ts

### Do:
- **Do** preserve sub-50ms UI feedback by relying on native AppKit/SwiftUI controls instead of web wrappers.
- **Do** format all keyboard shortcut annotations with standard macOS symbols (`⌘`, `⇧`, `⌥`).
- **Do** use continuous corner curvature (`style: .continuous`) for all rounded rectangles.
- **Do** strictly separate Gmail messages from GitHub open work items across isolated stream views.
- **Do** provide non-destructive local hide (`e`) and immediate visible Undo affordances for triage actions.

### Don't:
- **Don't** introduce heavy custom drop shadows to cards or list rows; rely on native macOS system materials.
- **Don't** use custom web fonts; San Francisco Pro and San Francisco Mono are mandatory.
- **Don't** mutate public GitHub status or close issues during triage.
- **Don't** allow JavaScript execution inside detail web views (`allowsContentJavaScript = false`).
