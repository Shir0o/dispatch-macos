# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Software developers context-switching between personal/work email (Gmail) and GitHub activity (code reviews, assigned issues, CI failures), frequently running local AI coding agents (`claude`, `opencode`, `antigravity`).

## Product Purpose

A lightweight, zero-overhead native macOS triage client for Gmail and GitHub. It replaces heavy Electron web wrappers and containerized background sync engines with a responsive, sub-50ms native client consuming less than 50 MB idle RAM.

## Positioning

Pure Swift 6 and SwiftUI desktop client built for keyboard-driven developer speed, stream isolation between email and GitHub work, and direct 1-click / hotkey integration with local terminal-based AI coding agents.

## Operating Context

- macOS 14+ (Sonoma and newer) on Apple Silicon and Intel Macs.
- Fast keyboard navigation loops (`j`/`k`, `e`, `s`, `u`, `#`, `Cmd+O`, `Cmd+Shift+A`).
- Local terminal emulators (Terminal, iTerm2, Ghostty, VS Code) running local CLI coding agents.
- Ephemeral snapshots on quit (`snapshot.json`) with credentials secured via the macOS Keychain.

## Capabilities and Constraints

- **Streams:** Dedicated stream isolation between Gmail inbox triage and GitHub Open Work.
- **GitHub Open Work:** Single involvement search (`is:open involves:@me`), capped at 400 items, refreshed every 15 minutes, with local-only hiding (`e`) and Undo banner. Never mutates public GitHub issue states during triage.
- **Agent Dispatch (`Cmd+Shift+A`):** Bundles issue/thread context into structured markdown prompts, writes to `NSPasteboard`, activates the selected local terminal agent, and pins context side-by-side.
- **Security & Sandboxing:** Recycled `WKWebView` detail renderer with JavaScript strictly disabled (`allowsContentJavaScript = false`), declarative CSP blocking tracking pixels, and automatic dark mode CSS injection.
- **No Background Daemons:** Standalone process without background sync daemons, containers, or Electron runtime dependencies.

## Brand Commitments

- **Tone & Identity:** Utilitarian, fast, high-performance developer tool adhering to macOS Human Interface Guidelines (HIG).
- **Aesthetic:** Clean native macOS styling using system materials, SF Pro/SF Mono, `NavigationSplitView`, and authentic platform controls.

## Evidence on Hand

- Production Swift 6 codebase under `Sources/DispatchApp`.
- Native app entitlements and sandbox configuration (`Dispatch.entitlements`, `Info.plist`).
- Comprehensive documentation: `README.md`, `design_draft.md`, `concepts_brief.md`, architecture and review reports.

## Product Principles

1. **Native Speed Over Web Conveniences:** Sub-50ms keyboard interaction latency and low idle memory (<50 MB); zero webview bloat for UI shells.
2. **Non-Destructive Triage Invariant:** Fast triage actions (`e`) archive email or hide Open Work items locally; they never close or modify public GitHub states without explicit intent.
3. **Stream Isolation:** Keep noisy GitHub alerts and notifications strictly separated from personal/work correspondence.
4. **Seamless Agent Handoff:** Bridge GitHub issues directly into local terminal coding agents with full context preservation and zero browser distraction.

## Accessibility & Inclusion

Full keyboard accessibility and navigation compliance, native VoiceOver support, dynamic type where appropriate, and macOS system high-contrast / dark mode compatibility.
