# Stage 7 Review Report: Critic Review

* **Target Document:** `/Users/twang/dev-triage-macos/docs/designs/dev_triage_macos.md`
* **Scope:** Lines 1..302 (`FeatureRange`)
* **Reviewers:** `egm-design`, `egm-structural`, `egm-style`
* **Standards:** `feature-spec-standard`
* **Mode:** REVIEW

---

## Severity Breakdown
* 🔴 **Blockers**: 2
* 🟡 **Majors**: 5
* 🟢 **Nits**: 3

---

## Prioritized Findings

### 1. App Sandbox Incompatibility with CLI Agent Dispatch & Terminal Scripting
* **Severity:** 🔴 Blocker
* **Affected Scope:** Lines 168–185, Lines 274–275, Lines 292–296
* **Discrepancy Description:** The design asserts strict enforcement of macOS App Sandbox (`com.apple.security.app-sandbox` with only `network.client` entitlement, lines 292–296) and cites sandbox preservation as the rationale for rejecting an embedded terminal (Alternative E, lines 274–275). Concurrently, Section 2.E (`AgentDispatchService`, lines 168–185) relies on launching external terminal emulators (Terminal.app, iTerm2, Ghostty) and executing CLI commands/scripts with dynamic arguments to run local agents (`claude`, `opencode`, `antigravity`). Under standard macOS App Sandbox constraints, `NSWorkspace.shared.openApplication(at:configuration:)` ignores command-line arguments passed to external applications, and spawning terminal subprocesses via Apple Events / AppleScript requires `com.apple.security.automation.apple-events` with specific target application entitlements. Furthermore, passing structured prompts via temporary files outside the sandboxed container directory is blocked by default sandbox file quarantines.
* **Rationale & Recommendation:** The architectural requirements for App Sandbox and out-of-process CLI agent dispatch are mutually incompatible as written. Explicitly define the sandbox distribution model: (1) If distributed via Mac App Store, declare the required temporary Apple Events entitlement exceptions (`com.apple.security.temporary-exception.apple-events`) for `com.apple.Terminal`, `com.googlecode.iterm2`, and `com.mitchellh.ghostty`, and use a shared App Group container for temporary prompt files; or (2) Explicitly declare Developer ID notarization outside the Mac App Store using Hardened Runtime without sandboxing, or (3) Adopt the clipboard copy + activate pattern (`Cmd+Shift+A` copies prompt to system clipboard and focuses terminal).

### 2. OAuth 2.0 PKCE Loopback Socket Blocked by Sandbox & Insecure GitHub Web Flow
* **Severity:** 🔴 Blocker
* **Affected Scope:** Lines 128–132, Lines 292–294
* **Discrepancy Description:** Section 2.A specifies using `ASWebAuthenticationSession` with a loopback redirect URI (`http://127.0.0.1:0/callback`) for Gmail, while Section Non-Functional Requirements restricts entitlements strictly to `com.apple.security.network.client` and outbound traffic to `googleapis.com` and `github.com`. A loopback redirect requires binding a local TCP server socket, which is prohibited under App Sandbox without the `com.apple.security.network.server` entitlement. Additionally, GitHub's standard OAuth 2.0 web flow does not support PKCE for client-side OAuth Apps without a client secret. Shipping a client secret inside the application bundle compromises credentials, while a native client without a backend proxy cannot safely complete GitHub's standard web authorization code grant.
* **Rationale & Recommendation:** Update the authentication design: (1) For Gmail, replace loopback socket redirects with a custom reverse-DNS URI scheme (`com.googleusercontent.apps.<client-id>:/oauth2redirect`) natively supported by `ASWebAuthenticationSession` without local TCP server socket listeners. (2) For GitHub, replace the standard web flow with GitHub Device Authorization Grant (RFC 8628, `POST /login/device/code`) or personal access token onboarding, which is specifically designed for client-only applications without client secrets.

### 3. Missing Body & Comments Properties in Domain Schema (`TriageItem`)
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 188–241 (`TriageItem` & `TriageKind`), Lines 160–166, Lines 220–240
* **Discrepancy Description:** The domain schema in Section 3 (`TriageItem` and `TriageKind`) omits body content, HTML payloads, and conversation comments. `TriageKind.email` provides only `(threadId: String, snippet: String, hasHtml: Bool)`, and `TriageKind.gitHubIssue` provides only `(number: Int, repo: String, state: String, isAssignedToMe: Bool)`. However, `DetailPaneView` (lines 160–166) requires rendering full email HTML and GitHub markdown, and `AgentDispatchPayload` (lines 220–240) requires `body: String` and `comments: [String]`.
* **Rationale & Recommendation:** Define the secondary fetch pipeline, caching/eviction rules, and offline behavior for detailed message bodies and issue comment timelines, or add `body: String?` and `comments: [IssueComment]?` directly to the domain model and clarify serialization in the quit snapshot.

### 4. Gmail Incremental Sync Thread vs. Message Identifier Inconsistency
* **Severity:** 🟡 Major
* **Affected Scope:** Line 59, Lines 137–139, Lines 153–155, Line 199, Line 338
* **Discrepancy Description:** The document conflates Gmail message-level operations with thread-level operations. CUJ 1 (line 59) states that pressing `e` removes the `INBOX` label on unwanted threads. However, Section 2.C (line 154) and Section 2.B (line 138) state that the coordinator inspects message IDs and calls `users.messages.modify(removeLabelIds: ["INBOX"])`. In Gmail's data model, removing `INBOX` from an individual message leaves the parent thread visible in the inbox if other messages in the thread retain the `INBOX` label.
* **Rationale & Recommendation:** Standardize triage operations on thread endpoints: use `users.threads.get(id:)` and `users.threads.modify(threadId: ..., removeLabelIds: ["INBOX"])`, or explicitly define whether single-message splitting is permitted.

### 5. Recycled `WKWebView` Data Leakage & Inadequate Remote Asset Blocking
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 160–165, Line 295
* **Discrepancy Description:** Reusing a single `WKWebView` instance across multiple emails without resetting `WKWebsiteDataStore` or reloading an isolated blank page creates a risk of state and origin leakage (cookies, storage, DOM remnants). Furthermore, relying solely on rewriting HTML `<img src>` tags fails to prevent tracking beacons loaded via CSS `background-image: url(...)`, `@import`, SVG `<image xlink:href="...">`, or responsive `<picture>` / `<source>` tags.
* **Rationale & Recommendation:** Specify injecting a Content Security Policy (CSP) meta tag (`default-src 'none'; style-src 'unsafe-inline'; font-src local:`) or registering a custom `WKURLSchemeHandler` to intercept all subresource network requests deterministically before they reach the network stack. Explicitly document clearing the webview cache between thread transitions.

### 6. Premature Closure of "Open Questions" & Lack of Non-Happy Path CUJs
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 48–50, Lines 54–70
* **Discrepancy Description:** Section "Open Questions" asserts "None currently open", disregarding unresolved engineering dependencies such as Google OAuth verification tier requirements for sensitive Gmail scopes (`gmail.modify`), GitHub API secondary rate limits on check-suite queries, and terminal environment discovery ($PATH resolution for non-standard shells like fish/homebrew). Concurrently, Section "Critical User Journeys" provides only 3 happy-path flows, omitting failure and recovery paths.
* **Rationale & Recommendation:** Reopen the "Open Questions" section to document Google Cloud OAuth verification constraints and CLI agent path resolution. Add two critical user journeys covering error states: (1) OAuth token revocation / re-authentication flow, and (2) Offline conflict resolution when optimistic triage modifications fail during extended disconnections.

### 7. Ambiguous Inter-Process Protocol for Terminal & Agent Dispatch
* **Severity:** 🟡 Major
* **Affected Scope:** Lines 168–185
* **Discrepancy Description:** Section 2.E relies on ambiguous language: "Uses `NSWorkspace.shared.openApplication` or terminal script... with the prompt passed via temporary file or command argument." This is indecisive and masks integration complexity across different terminal emulators (Terminal, iTerm2, Ghostty).
* **Rationale & Recommendation:** Define a concrete IPC contract: specify writing the formatted markdown prompt to a temporary file (`$TMPDIR/devtriage-agent-prompt-<uuid>.md`) and executing a defined shell dispatch script or terminal URL scheme with explicit error handling if the target CLI agent binary is absent from the user's path.

### 8. Unhandled Focus State Machine for Single-Key Keyboard Navigation
* **Severity:** 🟢 Nit
* **Affected Scope:** Line 31, Line 85, Line 103, Line 362
* **Discrepancy Description:** Single-key shortcuts (`j`, `k`, `e`, `s`, `u`) are defined without specifying a modal focus state machine. When text inputs (search bar, filter query, settings) gain focus, single-key handlers will intercept typing unless explicitly suppressed.
* **Rationale & Recommendation:** Add an explicit requirement for a `FocusState` guard in `KeyboardShortcutModifier` that suspends single-key navigation when any search or text input field is active.

### 9. Plaintext JSON Snapshot Data-at-Rest Exposure
* **Severity:** 🟢 Nit
* **Affected Scope:** Lines 157–158
* **Discrepancy Description:** The local cache file `~/Library/Application Support/DevTriage/snapshot.json` is explicitly specified as "unencrypted JSON", leaving private email subject lines, author emails, and GitHub notification metadata exposed in plaintext on disk.
* **Rationale & Recommendation:** Specify writing the snapshot with `Data.WritingOptions.completeFileProtection` to ensure encryption at rest when the macOS device is locked.

### 10. Weakly Typed Properties and Redundant Flags in `TriageKind`
* **Severity:** 🟢 Nit
* **Affected Scope:** Lines 198–203
* **Discrepancy Description:** In `TriageKind`, `hasHtml: Bool` on `case email` is redundant given MIME multi-part structure. Additionally, `reviewStatus: String` and `ciStatus: String` in `case gitHubPullRequest` use unconstrained strings rather than Swift enums.
* **Rationale & Recommendation:** Refactor `reviewStatus` and `ciStatus` into strongly typed Swift enums (`ReviewStatus`, `CheckSuiteStatus`) to leverage compiler-enforced pattern matching under Swift 6.
