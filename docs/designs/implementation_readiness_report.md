# Stage 9 Review Report: Implementation Readiness Test

* **Target Document:** `/Users/twang/dev-triage-macos/docs/designs/dev_triage_macos.md`
* **Scope:** Lines 303..414 (`DetailedRange`)
* **Reviewers:** `egm-implementation-readiness`, `egm-codebase-details`, `egm-style`
* **Standards:** `implementation-readiness-standard`
* **Mode:** REVIEW

---

## Severity Summary

| Severity | Count |
| --- | --- |
| 🔴 Blocker | 3 |
| 🟡 Major | 5 |
| 🟢 Nit | 3 |
| **Total** | **11** |

---

## Prioritized Findings

### 1. GitHub Service Missing Issue Details & Comment APIs Required by Detail Pane & Agent Dispatch
* **Severity:** 🔴 Blocker
* **Affected Scope:** Lines 340–346 (`GitHubService.swift`), Lines 371–374 (`DetailPaneView.swift`), Lines 355–358 (`AgentDispatchService.swift`), Lines 315–318 (`TriageItem.swift`)
* **Discrepancy Description:** `DetailPaneView` is specified to display the issue header, state pills, action bar, and "full comment timeline." `AgentDispatchService` is specified to extract issue body text, reproduction steps, and recent conversation comments into an `AgentDispatchPayload`. However, `TriageItem` and `TriageKind` in the domain model only hold shallow notification metadata and no body or comment timeline. Crucially, `GitHubService` defines only `fetchNotifications`, `batchFetchPRDetails`, and `dismissNotification`. There are zero endpoints or client methods defined to fetch issue/PR descriptions, timeline events, or comments (`GET /repos/{owner}/{repo}/issues/{number}` and `GET /repos/{owner}/{repo}/issues/{number}/comments`). An engineer or autonomous agent cannot implement `DetailPaneView` or `AgentDispatchService` without inventing missing endpoints, models, and network flows.
* **Rationale & Recommendation:** Add explicit methods to `GitHubService.swift` (e.g., `fetchIssueDetails(repo: String, number: Int) async throws -> GitHubIssueDetail` resolving markdown body and comment thread). Define corresponding detail models in `TriageItem.swift` or a dedicated model target.

### 2. App Sandbox Incompatibility with External CLI Agent and Terminal Invocation
* **Severity:** 🔴 Blocker
* **Affected Scope:** Lines 355–358 (`AgentDispatchService.swift`), Line 403 (`Verification Plan`), Section 2.E / Non-Functional Requirements (lines 292–296)
* **Discrepancy Description:** The plan mandates strict macOS App Sandbox compliance (`com.apple.security.app-sandbox` at line 293 and line 403). At the same time, Target File 10 (`AgentDispatchService.swift`) states that it "launches the user's configured terminal emulator (Terminal, iTerm2, Ghostty) running their CLI agent (`claude`, `opencode`, `antigravity`)" targeting a local repository path (`localRepoPath: URL?`). Under macOS App Sandbox, a sandboxed process cannot spawn arbitrary subprocesses outside its bundle, launch external terminal applications with shell command arguments without Apple Events entitlements, or read arbitrary local Git working trees outside its container without security-scoped bookmarks.
* **Rationale & Recommendation:** Adopt the minimalist clipboard dispatch flow: format the structured markdown prompt and copy it directly to `NSPasteboard.general`, display a 1.5s toast, and bring the user's terminal/IDE to the foreground via `NSWorkspace.shared.openApplication(at:...)` without injecting raw command strings. This requires zero sandbox exception entitlements and works across all terminal emulators and IDEs.

### 3. Missing `Info.plist`, Entitlements File, and App Bundle Configuration in Target Files
* **Severity:** 🔴 Blocker
* **Affected Scope:** Lines 307–310 (`Package.swift`), Line 403 (`Verification Plan`), Target Files manifest (lines 305–390)
* **Discrepancy Description:** The plan specifies building via pure Swift Package Manager (`swift build -c release`) and verifying App Sandbox entitlements with `codesign -d --entitlements :- .build/release/DevTriage`. However, no `DevTriage.entitlements` file is listed in the 18 target files to create. Pure `swift build` produces a Mach-O command-line binary, not a macOS `.app` bundle. A sandboxed macOS GUI app requires an `Info.plist` and bundle directory structure. SPM does not embed code signing entitlements during `swift build` without an explicit packaging step.
* **Rationale & Recommendation:** Add `DevTriage.entitlements` and `Info.plist` to the Target Files list. Detail the packaging strategy in the build plan (e.g., a lightweight `scripts/package-app.sh` that structures `.build/release/DevTriage` into `DevTriage.app`, copies `Info.plist`, and runs `codesign --entitlements DevTriage.entitlements -s - DevTriage.app`).

### 4. Invalid System Framework Dependencies in `Package.swift` Target Declaration
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 307–310 (`Package.swift`)
* **Discrepancy Description:** Line 309 states: "Declares dependencies strictly on Apple standard frameworks (`Foundation`, `SwiftUI`, `AuthenticationServices`, `WebKit`, `Security`, `Network`)." In Swift Package Manager (`Package.swift`), standard Apple SDK frameworks cannot be declared in the target's `dependencies: [...]` parameter. Doing so causes an SPM manifest parsing error (`product 'Foundation' not found`).
* **Rationale & Recommendation:** Clarify that the `Package.swift` target dependencies array is empty (`dependencies: []`), and that Apple SDK frameworks are linked automatically via `import` statements in source files.

### 5. Missing User Preferences / Settings Domain Model and View
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 305–390 (Target Files manifest) and Section 2.E (line 173)
* **Discrepancy Description:** The design relies on several user-configured settings: mapping GitHub repositories to local Git paths, terminal choice, and personal Google Cloud Client ID. However, no file in the target list handles preferences, settings storage, or UI (e.g. `PreferencesStore.swift`, `SettingsView.swift`).
* **Rationale & Recommendation:** Add `Sources/DevTriage/State/PreferencesStore.swift` and `Sources/DevTriage/Views/SettingsView.swift` to the target files to provide a concrete implementation path for persistence and configuration UI.

### 6. Unspecified Composition Root and Dependency Injection Wiring
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 311–350 (`DevTriageApp.swift`, `TriageStore.swift`, `SyncCoordinator.swift`, `AuthService.swift`, `GmailService.swift`, `GitHubService.swift`)
* **Discrepancy Description:** `DevTriageApp.swift` only instantiates `@State private var store = TriageStore()`. The plan fails to define how `SyncCoordinator`, `AuthService`, `GmailService`, and `GitHubService` are initialized, how credentials flow from `AuthService` into network services, and how `URLSession` instances are injected for testing via `URLProtocol`.
* **Rationale & Recommendation:** Define the composition root in `DevTriageApp.swift`, specify that `GmailService` and `GitHubService` take `init(session: URLSession = .shared, authService: AuthService)`, and clarify service delegation.

### 7. App-Quit Data Loss Hazard in SnapshotManager Asynchronous Persistence
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 351–354 (`SnapshotManager.swift`), Line 313 (`DevTriageApp.swift`)
* **Discrepancy Description:** Line 353 states that `SnapshotManager` "asynchronously writes in-memory triage items to `~/Library/Application Support/DevTriage/snapshot.json` on app quit." In macOS AppKit/SwiftUI lifecycle, when an application receives `willTerminateNotification`, an unawaited detached asynchronous task (`Task { ... }`) is not guaranteed to execute before the OS terminates the process.
* **Rationale & Recommendation:** Specify synchronous atomic writing (`Data.write(to:options: .atomic)`) during app quit, or fold snapshot persistence directly into `TriageStore` with debounced autosaving.

### 8. GitHub OAuth 2.0 PKCE Specification Mismatch
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 327–330 (`AuthService.swift`) and Section 2.A (line 130)
* **Discrepancy Description:** `AuthService.swift` states it implements PKCE for both Gmail and GitHub. However, standard GitHub OAuth web application flow does not support PKCE without a `client_secret`. Storing a `client_secret` in a public native client violates security best practices.
* **Rationale & Recommendation:** Specify GitHub Personal Access Token (PAT) input in settings or GitHub Device Authorization Flow (RFC 8628), reserving OAuth PKCE for Google/Gmail where it is natively supported for desktop clients.

### 9. ASWebAuthenticationSession Loopback Callback Specification Ambiguity
* **Severity:** 🟢 Nit
* **Affected Scope:** Line 329 (`AuthService.swift`) and Line 130
* **Discrepancy Description:** Line 130 specifies `http://127.0.0.1:0/callback` alongside `ASWebAuthenticationSession`. `ASWebAuthenticationSession` requires a custom scheme (e.g., `devtriage://` or reversed Google client ID) rather than a local loopback port listener.
* **Rationale & Recommendation:** Clarify that `AuthService` registers and uses a custom redirect URI scheme (`devtriage://oauth-callback` or `com.googleusercontent.apps.<client-id>:/oauth2redirect`) matching `ASWebAuthenticationSession(callbackURLScheme:completionHandler:)`.

### 10. Missing Initial Unauthenticated / Empty State View
* **Severity:** 🟢 Nit
* **Affected Scope:** Lines 359–378 (Target Files 11–15)
* **Discrepancy Description:** The target file list defines `MainSplitView`, `SidebarView`, `TriageStreamView`, and `DetailPaneView`, but lacks a view or sheet for first-launch authentication or account setup when Keychain tokens are missing.
* **Rationale & Recommendation:** Add an `OnboardingView.swift` or `AccountConnectionSheet.swift` component to handle the initial unauthenticated state.

### 11. Verification Plan Lacks Explicit Entitlement Signing Command
* **Severity:** 🟢 Nit
* **Affected Scope:** Lines 393–403 (`Verification Plan`)
* **Discrepancy Description:** Line 403 tests entitlements via `codesign -d --entitlements :- .build/release/DevTriage`, but the build steps only specify `swift build -c release`, which does not sign or apply entitlements.
* **Rationale & Recommendation:** Include the explicit signing command (e.g. `codesign --force --entitlements DevTriage.entitlements -s - ...`) in the build/verification section.
