# Consolidated EGM Review Report: DevTriage for macOS

* **Target Document:** `/Users/twang/dev-triage-macos/docs/designs/dev_triage_macos.md`
* **Execution Preset:** Uninterrupted Full Flow (All 5 Review Rubrics)
* **Status:** Complete
* **Date:** 2026-11-03

---

## Executive Summary

The five-stage EGM review protocol evaluated `dev_triage_macos.md` across architecture, comprehension, system design, high-altitude minimalism, and implementation readiness.

The core value proposition—a native Swift 6 and SwiftUI client delivering sub-50ms triage response with an idle memory footprint under 50 MB and zero Docker or Electron dependencies—is validated as architecturally sound. However, the reviews identified five critical implementation blockers:
1. An incompatibility between macOS App Sandbox and terminal CLI script execution.
2. Missing GitHub issue body and comment endpoints needed by the detail pane and agent dispatch.
3. Incomplete Gmail inbox bootstrapping and thread-level state synchronization.
4. Mismatched OAuth 2.0 PKCE loopback sockets and client-side GitHub OAuth grants.
5. Missing macOS application bundle metadata (`Info.plist`), code signing entitlements, and packaging scripts.

Simultaneously, the Zoom Out review successfully struck down proposed over-engineering traps (such as multi-terminal AppleScript engines, custom WebKit scheme interceptors, and complex offline relational sync databases), preserving the project's strict minimalism.

---

## Actionable Consolidated Findings

### 🔴 Blockers (Must Resolve Before Implementation)

#### 1. App Sandbox Incompatibility with CLI Agent Dispatch
* **Issue:** The document mandates strict App Sandbox compliance (`com.apple.security.app-sandbox`), but proposes executing external CLI agents (`claude`, `opencode`, `antigravity`) with dynamic shell arguments inside external terminal emulators. Sandboxed macOS applications cannot inject commands or send Apple Events without temporary entitlement exceptions and complex IPC files.
* **Consolidated Action:** Adopt the **Clipboard Context Dispatch** pattern:
  1. Pressing `Cmd+Shift+A` formats the issue context and copies it directly to the system clipboard (`NSPasteboard.general`).
  2. Displays an unobtrusive 1.5-second toast: *"Issue context copied to clipboard"*.
  3. Activates the user's terminal or IDE via `NSWorkspace.shared.openApplication(at:...)` without injecting raw command strings.
  4. The user pastes (`Cmd+V`) and runs the agent in their active CLI session.
* **Benefits:** Requires zero sandbox exception entitlements, zero AppleScript code, zero temporary file cleanup, and works universally across all terminal emulators (Terminal, iTerm2, Ghostty, Alacritty, VS Code).

#### 2. Missing GitHub Issue Detail & Comment Endpoints in Data Pipeline
* **Issue:** `DetailPaneView` requires rendering a full markdown comment timeline, and `AgentDispatchService` requires extracting the issue body, reproduction steps, and discussion comments. However, `TriageItem` contains no body/comment fields, and `GitHubService` defines only notification and PR check methods.
* **Consolidated Action:** 
  1. Add `fetchIssueDetails(repo: String, number: Int) async throws -> GitHubIssueDetail` to `GitHubService.swift`.
  2. Define an `IssueDetail` model containing markdown description and timeline comments.
  3. Fetch issue details on demand upon selection in `DetailPaneView`, caching them in memory for the active session.

#### 3. Incomplete Gmail Initial Inbox Bootstrapping & Thread Invariants
* **Issue:** The document specifies bootstrapping sync via `users.history.list`. However, `history.list` only returns mutations occurring *after* the provided `historyId`. On a fresh cold start or after an HTTP 404 `INVALID_HISTORY_ID` invalidation, `history.list` returns an empty list. Furthermore, calling `users.messages.modify` archives an individual message rather than the entire thread.
* **Consolidated Action:**
  1. Add `fetchInboxThreads(pageToken: String?) async throws -> ThreadListResponse` using `users.threads.list(q: "label:INBOX")` for initial bootstrap and full reconciliation.
  2. Standardize all triage operations on thread endpoints: `users.threads.get` and `users.threads.modify(threadId: ..., removeLabelIds: ["INBOX"])`.

#### 4. OAuth 2.0 PKCE Loopback Socket & GitHub Auth Mismatch
* **Issue:** Specifying `http://127.0.0.1:0/callback` requires binding a local TCP server socket, prohibited by App Sandbox without `network.server`. Additionally, GitHub's standard OAuth web flow does not support PKCE without exposing a client secret.
* **Consolidated Action:**
  1. For Gmail: Use a custom reverse-DNS URI scheme (`com.googleusercontent.apps.<client-id>:/oauth2redirect`) natively supported by `ASWebAuthenticationSession` without local TCP server socket listeners.
  2. For GitHub: Use **Personal Access Token (PAT)** authentication entered during setup and stored in Keychain. This eliminates client secrets, loopback listeners, and device polling loops.

#### 5. Missing `Info.plist`, Entitlements File, and App Packaging
* **Issue:** SPM's `swift build -c release` produces a raw Mach-O binary. A sandboxed macOS GUI app requires an `Info.plist`, an entitlements file, and a `.app` bundle structure to be code-signed and executed.
* **Consolidated Action:**
  1. Add `DevTriage.entitlements` and `Info.plist` to the project manifest.
  2. Add a packaging script (`scripts/package-app.sh`) that bundles the executable, copies `Info.plist`, and executes `codesign --force --entitlements DevTriage.entitlements -s - DevTriage.app`.

---

### 🟡 Majors (High-Impact Simplifications & Robustness)

#### 6. Eliminate Premature Dual Protocols (Drop GraphQL in Favor of Strict REST v3)
* **Consolidated Action:** Remove GitHub GraphQL queries. Query PR check runs via REST endpoint `/repos/{owner}/{repo}/commits/{ref}/check-runs` on demand. This removes an entire protocol layer and cuts network parsing boilerplate in half.

#### 7. Replace Custom LRU Eviction Engine with Array Slicing
* **Consolidated Action:** Remove the custom LRU eviction algorithm and dedicated test suite. Cap in-memory collections with a single line: `items = Array(items.prefix(500))`.

#### 8. Add Minimalist Settings & Onboarding Scene
* **Consolidated Action:** Add `SettingsView.swift` and `PreferencesStore.swift` to target files. Provide configuration for Google OAuth Client ID, GitHub PAT, default local projects directory (`~/Developer` or `~/Code`), and preferred terminal application. Add an initial setup card when Keychain tokens are missing.

#### 9. Unify Mutation Architecture Between TriageStore and Services
* **Consolidated Action:** Define the composition root in `DevTriageApp.swift`. Inject `GmailService` and `GitHubService` directly into `TriageStore` for optimistic local UI removal with automatic rollback on network failure.

#### 10. Synchronous Atomic Write for Quit Snapshot
* **Consolidated Action:** Fold snapshot loading and saving directly into `TriageStore` (eliminating `SnapshotManager.swift`). Use synchronous atomic writing (`Data.write(to:options: [.atomic, .completeFileProtection])`) during `willTerminateNotification` to prevent app-quit data loss and encrypt data at rest.

#### 11. Declarative Content Security Policy for WebKit
* **Consolidated Action:** Reject custom AppKit scheme handlers. Inject `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src local:">` into HTML bodies to block tracking pixels and remote assets deterministically, with an on-demand button to load external media.

---

### 🟢 Nits (Quality & Polish)

#### 12. Correct `Package.swift` Target Declaration
* Remove standard Apple SDK frameworks (`Foundation`, `SwiftUI`, etc.) from SPM target `dependencies: []`. Link them via standard `import` statements.

#### 13. Remove Speculative Timer Jitter
* Replace `±5s` randomized timer jitter with a standard `Task.sleep(for: .seconds(45))` loop.

#### 14. Add Keyboard FocusState Guard
* Suppress single-key navigation (`j`/`k`, `e`, `s`, `u`) when text fields or search bars are focused.

#### 15. Clarify Trash Action Semantics
* Specify that `#`/`Delete` executes `users.threads.trash` on Gmail threads and dismisses/unsubscribes GitHub notifications.

#### 16. Strongly Typed Enums in Domain Models
* Refactor `reviewStatus: String` and `ciStatus: String` into strongly typed Swift enums (`ReviewStatus`, `CheckSuiteStatus`).

---

## Traceability Matrix

| Review Stage | Raw Finding ID & Title | Consolidated Action Item |
| :--- | :--- | :--- |
| **Stage 5 (Initial Zoom Out)** | Finding 1: Sandbox Violation & Terminal Execution | **Item 1** (Clipboard Context Dispatch) |
| **Stage 5 (Initial Zoom Out)** | Finding 2: Premature Dual-Protocol GitHub Layer | **Item 6** (Strict REST v3) |
| **Stage 5 (Initial Zoom Out)** | Finding 3: Premature 500-Item LRU Eviction Engine | **Item 7** (Array Slicing) |
| **Stage 5 (Initial Zoom Out)** | Finding 4: Ambiguous State Mutation Flow | **Item 9** (Composition Root & Service Injection) |
| **Stage 5 (Initial Zoom Out)** | Finding 5: Missing First-Run Credential Configuration | **Item 8** (Settings & Onboarding Scene) |
| **Stage 5 (Initial Zoom Out)** | Finding 6: Speculative Randomized Polling Jitter | **Item 13** (Remove Timer Jitter) |
| **Stage 5 (Initial Zoom Out)** | Finding 7: Unnecessary Single-Use Abstractions | **Item 10** (Fold Snapshot into Store) |
| **Stage 5 (Initial Zoom Out)** | Finding 8: Misleading Full MIME Parsing Terminology | **Item 3** (JSON MIME Body Extraction) |
| **Stage 6 (Comprehension)** | Finding 1: Initial Bootstrap & Reconciliation Deficiencies | **Item 3** (Thread List Bootstrap) |
| **Stage 6 (Comprehension)** | Finding 2: Missing GitHub Issue Details & Comments | **Item 2** (Issue Details API) |
| **Stage 6 (Comprehension)** | Finding 3: Incompatible Sandbox Permissions for CLI Launch | **Item 1** (Clipboard Context Dispatch) |
| **Stage 6 (Comprehension)** | Finding 4: Missing Persistence Model for Preferences | **Item 8** (Settings & Onboarding Scene) |
| **Stage 6 (Comprehension)** | Finding 5: GitHub OAuth PKCE Mismatch | **Item 4** (GitHub PAT Auth) |
| **Stage 6 (Comprehension)** | Finding 6: Undefined Loopback Listener on Port 0 | **Item 4** (Reverse-DNS Custom Scheme) |
| **Stage 6 (Comprehension)** | Finding 7: Incomplete Definition of Trash Shortcut | **Item 15** (Trash Action Semantics) |
| **Stage 6 (Comprehension)** | Finding 8: Mismatched Thread vs Message Archive API | **Item 3** (Thread-Level Endpoints) |
| **Stage 7 (Critic)** | Finding 1: App Sandbox Incompatibility with CLI Dispatch | **Item 1** (Clipboard Context Dispatch) |
| **Stage 7 (Critic)** | Finding 2: OAuth PKCE Loopback & Insecure GitHub Flow | **Item 4** (Reverse-DNS & PAT) |
| **Stage 7 (Critic)** | Finding 3: Missing Body & Comments in Domain Schema | **Item 2** (Issue Details API & Models) |
| **Stage 7 (Critic)** | Finding 4: Gmail Incremental Sync Thread Conflation | **Item 3** (Thread-Level Endpoints) |
| **Stage 7 (Critic)** | Finding 5: Recycled WKWebView Tracking Leakage | **Item 11** (Declarative CSP Meta Tag) |
| **Stage 7 (Critic)** | Finding 7: Ambiguous Inter-Process Protocol | **Item 1** (Clipboard Context Dispatch) |
| **Stage 7 (Critic)** | Finding 8: Unhandled Focus State Machine | **Item 14** (FocusState Guard) |
| **Stage 7 (Critic)** | Finding 9: Plaintext JSON Snapshot Data-at-Rest | **Item 10** (Atomic Encrypted Writing) |
| **Stage 7 (Critic)** | Finding 10: Weakly Typed Properties in TriageKind | **Item 16** (Strongly Typed Enums) |
| **Stage 8 (Intermediate Zoom Out)** | Upstream Triage: Reject AppleScript & IPC Weeds | **Item 1** (Clipboard Context Dispatch) |
| **Stage 8 (Intermediate Zoom Out)** | Upstream Triage: Reject Offline Relational Databases | Preserved Non-Goal 3 (In-Memory Only) |
| **Stage 8 (Intermediate Zoom Out)** | Upstream Triage: Reject Custom WKScheme Handlers | **Item 11** (Declarative CSP Meta Tag) |
| **Stage 9 (Implementation Readiness)** | Finding 1: Missing Issue Details & Comment APIs | **Item 2** (Issue Details API) |
| **Stage 9 (Implementation Readiness)** | Finding 2: App Sandbox Incompatibility with Terminal | **Item 1** (Clipboard Context Dispatch) |
| **Stage 9 (Implementation Readiness)** | Finding 3: Missing Info.plist, Entitlements & Packaging | **Item 5** (App Bundle & Packaging) |
| **Stage 9 (Implementation Readiness)** | Finding 4: Invalid Framework Dependencies in SPM | **Item 12** (Fix Package.swift) |
| **Stage 9 (Implementation Readiness)** | Finding 5: Missing Settings Model & View in File Manifest | **Item 8** (Settings & Onboarding Scene) |
| **Stage 9 (Implementation Readiness)** | Finding 6: Unspecified Composition Root & Injection | **Item 9** (Composition Root & Service Injection) |
| **Stage 9 (Implementation Readiness)** | Finding 7: App-Quit Asynchronous Data Loss Hazard | **Item 10** (Synchronous Atomic Write) |
| **Stage 9 (Implementation Readiness)** | Finding 8: GitHub OAuth PKCE Mismatch | **Item 4** (GitHub PAT Auth) |
| **Stage 9 (Implementation Readiness)** | Finding 9: ASWebAuthenticationSession Custom Scheme | **Item 4** (Reverse-DNS Custom Scheme) |
| **Stage 9 (Implementation Readiness)** | Finding 10: Missing Initial Unauthenticated State View | **Item 8** (Settings & Onboarding Scene) |
| **Stage 9 (Implementation Readiness)** | Finding 11: Verification Plan Lacks Explicit Signing | **Item 5** (App Bundle & Packaging) |

---
*Consolidated review report compiled via EGM Review Protocol.*
