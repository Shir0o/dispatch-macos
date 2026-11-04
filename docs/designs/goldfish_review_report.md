# Goldfish Annotated Review Report

**Target:** `/Users/twang/dev-triage-macos/docs/designs/dev_triage_macos.md` (`full file`, lines 1..414)  
**Status:** resolved (All 16 findings auto-accepted and applied to `dev_triage_macos.md`)

## Prioritized Findings & Resolution Summary

### Issue 1: App Sandbox Incompatibility with CLI Agent Dispatch [`egm-design` / `egm-zoom-out`] - Severity: High
* **Affected Scope:** Section 2.E, Non-Functional Requirements, Target File 9 (`AgentDispatchService.swift`)
* **Discrepancy Description:** Sandboxed macOS apps cannot execute external terminal AppleScript commands or dynamic shell scripts without temporary exception entitlements.
* **Rationale:** Violates App Sandbox rules and adds fragile multi-terminal scripting maintenance.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Replaced terminal scripting execution with Clipboard Context Dispatch (`NSPasteboard.general` copying + 1.5s toast + `NSWorkspace.shared.openApplication` activation of user's configured terminal/IDE). Eliminates sandbox exceptions while preserving side-by-side context reference.

---

### Issue 2: Missing GitHub Issue Details and Comments APIs [`egm-comprehension` / `egm-implementation-readiness`] - Severity: High
* **Affected Scope:** `GitHubService.swift`, `DetailPaneView.swift`, `TriageItem.swift`
* **Discrepancy Description:** The detail pane renders issue markdown and comments, and agent dispatch bundles comments, but `GitHubService` and `TriageItem` only defined shallow notification titles.
* **Rationale:** Missing data pipeline and endpoints make the detail pane and agent dispatch impossible to implement without inventing APIs.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Added `fetchIssueDetails(repo: String, number: Int) async throws -> GitHubIssueDetail` to `GitHubService.swift`. Declared `GitHubIssueDetail` and `GitHubComment` domain models in Section 3 and Target File 3.

---

### Issue 3: Incomplete Gmail Initial Inbox Bootstrapping & Thread Invariants [`egm-comprehension` / `egm-design`] - Severity: High
* **Affected Scope:** Section 2.B, Section 2.C, Target File 6 (`GmailService.swift`)
* **Discrepancy Description:** `users.history.list` only returns mutations occurring after a baseline `historyId`, causing fresh installs to show empty inboxes. Calling `users.messages.modify` archives single messages rather than parent threads.
* **Rationale:** Sync coordinator cannot populate initial inboxes and risks leaving orphaned messages in the inbox.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Standardized all operations on threads. Added `fetchInboxThreads(pageToken:)` via `users.threads.list(q: "label:INBOX")` for initial bootstrap and full reconciliation. Specified atomic archiving via `users.threads.modify(threadId: ..., removeLabelIds: ["INBOX"])`.

---

### Issue 4: OAuth 2.0 PKCE Loopback Port & GitHub Flow Mismatch [`egm-design` / `egm-codebase-details`] - Severity: High
* **Affected Scope:** Section 2.A (`AuthService.swift`), Non-Functional Requirements
* **Discrepancy Description:** Loopback sockets (`127.0.0.1:0`) require prohibited server entitlements under App Sandbox. GitHub standard OAuth Apps do not support PKCE without exposing client secrets.
* **Rationale:** Desktop clients cannot safely embed client secrets or bind local TCP server sockets under App Sandbox.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Specified custom reverse-DNS URI scheme (`com.googleusercontent.apps.<id>:/oauth2redirect`) for Gmail with `ASWebAuthenticationSession`. Specified GitHub Personal Access Token (PAT) input in settings stored securely in macOS Keychain.

---

### Issue 5: Missing App Bundle Structure, Info.plist, and Entitlements [`egm-implementation-readiness`] - Severity: High
* **Affected Scope:** Target Files manifest, Verification Plan
* **Discrepancy Description:** SPM produces a bare Mach-O binary. A sandboxed macOS GUI app requires an `Info.plist`, an entitlements file, and a `.app` bundle structure to be code-signed.
* **Rationale:** App cannot be code-signed or launched as a native macOS application without bundle metadata.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Added Target Files 18 (`DevTriage.entitlements`), 19 (`Info.plist`), and 20 (`scripts/package-app.sh`). Updated Verification Plan to include packaging and code-sign verification commands.

---

### Issue 6: Eliminate Premature Dual Protocols (Drop GraphQL in Favor of Strict REST v3) [`egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Section 2.B, Target File 7 (`GitHubService.swift`)
* **Discrepancy Description:** Requiring raw GraphQL queries without third-party dependencies adds fragile query string escaping and manual JSON response parsing boilerplate.
* **Rationale:** Violates YAGNI and adds unnecessary protocol overhead.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Removed GraphQL references; specified strict GitHub REST API v3 `/repos/{owner}/{repo}/commits/{ref}/check-runs` endpoint for CI alert resolution.

---

### Issue 7: Replace Custom LRU Eviction Engine with Array Slicing [`egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Section 2.C, Target File 4 (`TriageStore.swift`), Target File 22 (`TriageStoreTests.swift`)
* **Discrepancy Description:** Implementing a custom LRU eviction data structure and unit test for 500 in-memory items (<100 KB RAM) is premature optimization.
* **Rationale:** An in-memory chronological list only needs simple array capping.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Replaced LRU data structure with `items = Array(items.prefix(500))`. Retargeted unit tests to array capping and atomic persistence.

---

### Issue 8: Add Minimalist Settings & Onboarding Architecture [`egm-implementation-readiness` / `egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Target Files manifest, Section 2.A
* **Discrepancy Description:** The design requires configuring Google Client ID, GitHub PAT, default local projects directory, and preferred terminal, but provides no settings UI or preferences storage.
* **Rationale:** Developers cannot onboard or input credentials without a configuration scene.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Added Target Files 10 (`PreferencesStore.swift`), 16 (`SettingsView.swift`), and 17 (`OnboardingView.swift`).

---

### Issue 9: Unify Mutation Architecture and Composition Root [`egm-implementation-readiness` / `egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Section 1 (System Architecture Mermaid Diagram), Section 2.C
* **Discrepancy Description:** Dependency injection wiring and mutation data flow between `TriageStore`, `SyncCoordinator`, and network services were ambiguous.
* **Rationale:** Engineers must know where services are instantiated and how optimistic mutations are executed.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Clarified composition root in `DevTriageApp.swift`. Injected `GmailService` and `GitHubService` directly into `TriageStore` for optimistic execution with rollback. Positioned `SyncCoordinator` as background polling emitter delivering fresh items to store.

---

### Issue 10: Synchronous Atomic Write for Quit Snapshot [`egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Section 2.C, Target File 4 (`TriageStore.swift`)
* **Discrepancy Description:** Asynchronous detached task execution during app termination risks process kill before the file is flushed.
* **Rationale:** Results in corrupted or missing `snapshot.json`.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Folded snapshot persistence directly into `TriageStore` (eliminating `SnapshotManager.swift`). Specified synchronous atomic write (`Data.write(to:options: .atomic)`) with `.completeFileProtection`.

---

### Issue 11: Declarative Content Security Policy for WebKit [`egm-critic` / `egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Section 2.D, Target File 15 (`RecycledWKWebView.swift`)
* **Discrepancy Description:** Subresource leaks (CSS `@import`, `background-image`) bypass standard tag rewriting.
* **Rationale:** Tracking pixels and external assets must be blocked deterministically without complex custom scheme handlers.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Injected `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src local:">` into HTML bodies, re-rendering with permissive CSP only when the user clicks "Load External Images".

---

### Issue 12: Correct `Package.swift` Target Declaration [`egm-codebase-details`] - Severity: Low
* **Affected Scope:** Target File 1 (`Package.swift`)
* **Discrepancy Description:** System frameworks (`Foundation`, `SwiftUI`) cannot be declared in SPM target `dependencies: [...]`.
* **Rationale:** Causes SPM manifest parsing failure.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Explicitly specified `dependencies: []` in `Package.swift`.

---

### Issue 13: Remove Speculative Timer Jitter [`egm-zoom-out`] - Severity: Low
* **Affected Scope:** Section 2.B
* **Discrepancy Description:** Adding ±5s randomized jitter to a single desktop client polling loop is unnecessary distributed systems complexity.
* **Rationale:** Violates YAGNI.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Removed ±5s jitter reference; specified fixed 45-second polling interval using `Task.sleep(for: .seconds(45))`.

---

### Issue 14: Add Keyboard FocusState Guard [`egm-critic`] - Severity: Low
* **Affected Scope:** Section 2, Target File 11 (`MainSplitView.swift`)
* **Discrepancy Description:** Single-key shortcuts (`j`/`k`, `e`, `s`, `u`, `#`) intercept text input if a search field is focused.
* **Rationale:** Prevents typing into text inputs.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Added `@FocusState private var isSearchFocused: Bool` guard in `MainSplitView.swift` to suspend single-key navigation when text inputs are active.

---

### Issue 15: Clarify Trash Action Semantics [`egm-comprehension`] - Severity: Low
* **Affected Scope:** Section 2.C, Target File 4 (`TriageStore.swift`)
* **Discrepancy Description:** Incomplete specification of `#`/`Delete` behavior.
* **Rationale:** Triage actions must have unambiguous server mappings.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Explicitly mapped `#`/`Delete` to `GmailService.trashThread` (`users.threads.trash`) for Gmail and `GitHubService.unsubscribeNotification` (`DELETE /notifications/threads/{id}/subscription`) for GitHub.

---

### Issue 16: Strongly Typed Enums in Domain Models [`egm-critic`] - Severity: Low
* **Affected Scope:** Section 3 (Data Schema and Domain Model)
* **Discrepancy Description:** Using unconstrained strings for `reviewStatus` and `ciStatus` bypasses Swift 6 type safety.
* **Rationale:** Enums provide compiler-checked pattern matching.
* **Decision:** AUTO-ACCEPTED (PROPOSE FIX)
* **Status:** Resolved
* **Applied Changes:** Added `ReviewStatus` (`pending`, `approved`, `changesRequested`, `none`) and `CheckSuiteStatus` (`queued`, `inProgress`, `completedSuccess`, `completedFailure`, `neutral`) enums, and updated `TriageKind.gitHubPullRequest`.
