# Goldfish Annotated Review Report

**Target:** `/Users/twang/dev-triage-macos/docs/designs/dev_triage_macos.md` (`full file`, lines 1..414)

## Prioritized Findings & AI Suggestions

### Issue 1: App Sandbox Incompatibility with CLI Agent Dispatch [`egm-design` / `egm-zoom-out`] - Severity: High
* **Affected Scope:** Section 2.E (Lines 168–185), Non-Functional Requirements (Line 293), Target Files (Lines 355–358)
* **Discrepancy Description:** Sandboxed macOS apps cannot execute external terminal AppleScript commands or dynamic shell scripts without temporary exception entitlements.
* **Rationale:** Violates App Sandbox rules and adds fragile multi-terminal scripting maintenance.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Adopting the Clipboard Context Dispatch pattern (`Cmd+Shift+A` copies structured markdown prompt to `NSPasteboard.general`, shows a 1.5s toast, and focuses the user's terminal/IDE) requires zero sandbox exception entitlements and works universally across all terminals (Terminal, iTerm2, Ghostty, Alacritty, VS Code).
* ***Proposed Edit:***
    * Location: Section 2.E, Section 3, Section 4 (Alternative E), and Target File 10
    * Change: Replace terminal scripting execution with `NSPasteboard.general` copying + `NSWorkspace.shared.openApplication` activation.

---

### Issue 2: Missing GitHub Issue Details and Comments APIs [`egm-comprehension` / `egm-implementation-readiness`] - Severity: High
* **Affected Scope:** Lines 340–346 (`GitHubService.swift`), Lines 371–374 (`DetailPaneView.swift`), Lines 315–318 (`TriageItem.swift`)
* **Discrepancy Description:** The detail pane renders issue markdown and comments, and agent dispatch bundles comments, but `GitHubService` and `TriageItem` only define shallow notification titles.
* **Rationale:** Missing data pipeline and endpoints make the detail pane and agent dispatch impossible to implement without inventing APIs.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Add `fetchIssueDetails(repo: String, number: Int) async throws -> GitHubIssueDetail` to `GitHubService.swift`. Define an on-demand `GitHubIssueDetail` model for active detail inspection.
* ***Proposed Edit:***
    * Location: Section 2.B, Section 3, and Target Files 3, 7, 14
    * Change: Define `fetchIssueDetails` in `GitHubService` and declare `GitHubIssueDetail` with `body: String` and `comments: [IssueComment]`.

---

### Issue 3: Incomplete Gmail Initial Inbox Bootstrapping & Thread Invariants [`egm-comprehension` / `egm-design`] - Severity: High
* **Affected Scope:** Lines 135–139, Line 154, Line 338 (`GmailService.swift`)
* **Discrepancy Description:** `users.history.list` only returns mutations occurring after a baseline `historyId`, causing fresh installs to show empty inboxes. Calling `users.messages.modify` archives single messages rather than parent threads.
* **Rationale:** Sync coordinator cannot populate initial inboxes and risks leaving orphaned messages in the inbox.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Standardize all operations on threads. Add `fetchInboxThreads(pageToken: String?)` via `users.threads.list(q: "label:INBOX")` for initial bootstrap and full reconciliation. Archive threads atomically via `users.threads.modify(threadId: ..., removeLabelIds: ["INBOX"])`.
* ***Proposed Edit:***
    * Location: Section 2.B, Section 2.C, and Target File 6
    * Change: Add `users.threads.list` bootstrapping and change all modify/archive calls to `users.threads.modify`.

---

### Issue 4: OAuth 2.0 PKCE Loopback Port & GitHub Flow Mismatch [`egm-design` / `egm-codebase-details`] - Severity: High
* **Affected Scope:** Lines 128–132 (`AuthService.swift`), Lines 292–294
* **Discrepancy Description:** Loopback sockets (`127.0.0.1:0`) require prohibited server entitlements under App Sandbox. GitHub standard OAuth Apps do not support PKCE without exposing client secrets.
* **Rationale:** Desktop clients cannot safely embed client secrets or bind local TCP server sockets under App Sandbox.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Use a custom reverse-DNS URI scheme (`com.googleusercontent.apps.<id>:/oauth2redirect`) for Gmail with `ASWebAuthenticationSession`. Use Personal Access Token (PAT) input in settings for GitHub, stored securely in macOS Keychain.
* ***Proposed Edit:***
    * Location: Section 2.A, Target File 5, and Non-Functional Requirements
    * Change: Replace loopback with reverse-DNS scheme for Gmail, and document PAT authentication for GitHub.

---

### Issue 5: Missing App Bundle Structure, Info.plist, and Entitlements [`egm-implementation-readiness`] - Severity: High
* **Affected Scope:** Lines 307–310 (`Package.swift`), Line 403 (`Verification Plan`), Target Files manifest
* **Discrepancy Description:** SPM produces a bare Mach-O binary. A sandboxed macOS GUI app requires an `Info.plist`, an entitlements file, and a `.app` bundle structure to be code-signed.
* **Rationale:** App cannot be code-signed or launched as a native macOS application without bundle metadata.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Add `DevTriage.entitlements`, `Info.plist`, and `scripts/package-app.sh` to target files and detail the packaging/signing command in the verification plan.
* ***Proposed Edit:***
    * Location: Detailed Implementation Plan (Target Files) and Verification Plan
    * Change: Add files 19 (`DevTriage.entitlements`), 20 (`Info.plist`), and 21 (`scripts/package-app.sh`).

---

### Issue 6: Eliminate Premature Dual Protocols (Drop GraphQL in Favor of Strict REST v3) [`egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Lines 140–143, Target File 7 (`GitHubService.swift`)
* **Discrepancy Description:** Requiring raw GraphQL queries without third-party dependencies adds fragile query string escaping and manual JSON response parsing boilerplate.
* **Rationale:** Violates YAGNI and adds unnecessary protocol overhead.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Use GitHub REST v3 exclusively: query `/repos/{owner}/{repo}/commits/{ref}/check-runs` directly on demand.
* ***Proposed Edit:***
    * Location: Section 2.B and Target File 7
    * Change: Remove GraphQL references; specify REST API v3 check-runs endpoint.

---

### Issue 7: Replace Custom LRU Eviction Engine with Array Slicing [`egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Lines 150–152, Target File 4 (`TriageStore.swift`), Target File 17
* **Discrepancy Description:** Implementing a custom LRU eviction data structure and unit test for 500 in-memory items (<100 KB RAM) is premature optimization.
* **Rationale:** An in-memory chronological list only needs simple array capping.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Cap items with `items = Array(items.prefix(500))`. Eliminate dedicated LRU test files.
* ***Proposed Edit:***
    * Location: Section 2.C, Target File 4, and Target File 17
    * Change: Replace LRU algorithm description with simple array prefix slicing.

---

### Issue 8: Add Minimalist Settings & Onboarding Architecture [`egm-implementation-readiness` / `egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Target Files manifest (lines 305–390), Section 2.A
* **Discrepancy Description:** The design requires configuring Google Client ID, GitHub PAT, default local projects directory, and preferred terminal, but provides no settings UI or preferences storage.
* **Rationale:** Developers cannot onboard or input credentials without a configuration scene.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Add `SettingsView.swift` and `PreferencesStore.swift` to manage credentials and local paths. Add an empty-state card when Keychain tokens are missing.
* ***Proposed Edit:***
    * Location: Target Files manifest (add Target Files 22 & 23)
    * Change: Add `PreferencesStore.swift` and `SettingsView.swift`.

---

### Issue 9: Unify Mutation Architecture and Composition Root [`egm-implementation-readiness` / `egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Lines 79–122 (Architecture Diagram), Lines 311–350
* **Discrepancy Description:** Dependency injection wiring and mutation data flow between `TriageStore`, `SyncCoordinator`, and network services are ambiguous.
* **Rationale:** Engineers must know where services are instantiated and how optimistic mutations are executed.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Specify the composition root in `DevTriageApp.swift`. Inject `GmailService` and `GitHubService` directly into `TriageStore` for optimistic local UI removal with automatic rollback on network failure.
* ***Proposed Edit:***
    * Location: Section 1 (Mermaid Diagram) and Section 2.C
    * Change: Clarify that `TriageStore` owns optimistic actions and calls services directly, while `SyncCoordinator` handles background polling.

---

### Issue 10: Synchronous Atomic Write for Quit Snapshot [`egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Lines 351–354 (`SnapshotManager.swift`), Line 313
* **Discrepancy Description:** Asynchronous detached task execution during app termination risks process kill before the file is flushed.
* **Rationale:** Results in corrupted or missing `snapshot.json`.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Fold snapshot persistence directly into `TriageStore` (eliminating `SnapshotManager.swift`). Use synchronous atomic writing with `.completeFileProtection`.
* ***Proposed Edit:***
    * Location: Section 2.C and Target File 9
    * Change: Remove `SnapshotManager.swift` and specify synchronous atomic file writing in `TriageStore`.

---

### Issue 11: Declarative Content Security Policy for WebKit [`egm-critic` / `egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Lines 160–166, Target File 15
* **Discrepancy Description:** Subresource leaks (CSS `@import`, `background-image`) bypass standard tag rewriting.
* **Rationale:** Tracking pixels and external assets must be blocked deterministically without complex custom scheme handlers.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Inject `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src local:">` into HTML bodies, re-rendering with permissive CSP only when the user clicks "Load Images".
* ***Proposed Edit:***
    * Location: Section 2.D and Target File 15
    * Change: Replace image-rewriting description with declarative CSP meta injection.

---

### Issue 12: Correct `Package.swift` Target Declaration [`egm-codebase-details`] - Severity: Low
* **Affected Scope:** Lines 307–310 (`Package.swift`)
* **Discrepancy Description:** System frameworks (`Foundation`, `SwiftUI`) cannot be declared in SPM target `dependencies: [...]`.
* **Rationale:** Causes SPM manifest parsing failure.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Set `dependencies: []` in `Package.swift`.
* ***Proposed Edit:***
    * Location: Target File 1
    * Change: Specify `dependencies: []` in SPM manifest.

---

### Issue 13: Remove Speculative Timer Jitter [`egm-zoom-out`] - Severity: Low
* **Affected Scope:** Lines 148–149
* **Discrepancy Description:** Adding ±5s randomized jitter to a single desktop client polling loop is unnecessary distributed systems complexity.
* **Rationale:** Violates YAGNI.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Use a standard `Task.sleep(for: .seconds(45))` loop.
* ***Proposed Edit:***
    * Location: Section 2.B
    * Change: Remove ±5s jitter reference.

---

### Issue 14: Add Keyboard FocusState Guard [`egm-critic`] - Severity: Low
* **Affected Scope:** Line 31, Line 362
* **Discrepancy Description:** Single-key shortcuts (`j`/`k`, `e`, `s`, `u`) intercept text input if a search field is focused.
* **Rationale:** Prevents typing into text inputs.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Add a `@FocusState` guard in `KeyboardShortcutModifier` that suspends single-key navigation when text inputs are active.
* ***Proposed Edit:***
    * Location: Section 2 and Target File 11
    * Change: Document focus state check for single-key modifiers.

---

### Issue 15: Clarify Trash Action Semantics [`egm-comprehension`] - Severity: Low
* **Affected Scope:** Line 31, Lines 321–325
* **Discrepancy Description:** Incomplete specification of `#`/`Delete` behavior.
* **Rationale:** Triage actions must have unambiguous server mappings.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Explicitly map `#`/`Delete` to `users.threads.trash` for Gmail and notification dismiss/unsubscribe for GitHub.
* ***Proposed Edit:***
    * Location: Section 2.C and Target File 4
    * Change: Add `trash(item:)` specification.

---

### Issue 16: Strongly Typed Enums in Domain Models [`egm-critic`] - Severity: Low
* **Affected Scope:** Lines 198–203
* **Discrepancy Description:** Using unconstrained strings for `reviewStatus` and `ciStatus` bypasses Swift 6 type safety.
* **Rationale:** Enums provide compiler-checked pattern matching.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:** Define `ReviewStatus` and `CheckSuiteStatus` Swift enums.
* ***Proposed Edit:***
    * Location: Section 3 (Data Schema and Domain Model)
    * Change: Update `TriageKind` struct with strongly typed enums.
