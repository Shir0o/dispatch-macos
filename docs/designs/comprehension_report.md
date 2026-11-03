# Stage 6 Review Report: Comprehension Test

* **Target Document:** `/Users/twang/dev-triage-macos/docs/designs/dev_triage_macos.md`
* **FeatureRange:** Lines 1..302
* **DetailedRange:** Lines 303..414
* **Reviewer:** `egm-comprehension` (Naive Reader)
* **Mode:** REVIEW

---

### What this proposes
This document specifies the technical design for DevTriage, a native macOS desktop client built with Swift 6 and SwiftUI for high-density triage of Gmail inboxes and GitHub notifications. The client establishes two isolated sidebar workspaces (Gmail and GitHub) operated entirely via single-key Vim/Superhuman shortcuts (`j`/`k`, `e`, `s`, `u`) with sub-16ms optimistic local state updates. To avoid the memory overhead of web runtimes (Electron) or containerization (Docker), the app interacts directly with Gmail and GitHub REST/GraphQL APIs and maintains an in-memory store capped at 500 items that serializes to a lightweight JSON snapshot on quit. Additionally, it introduces an out-of-process context dispatch shortcut (`Cmd+Shift+A`) that compiles GitHub issue metadata into a structured prompt and launches the developer's local terminal agent CLI (e.g., Claude Code, OpenCode, Antigravity) while keeping the issue detail pane pinned side-by-side for reference.

### How the existing system works, per this document
According to the document, software developers currently triage email and GitHub updates using electron aggregators, Docker-based sync daemons (like Mailspring or Nylas), Apple Mail, or web browser tabs, which incur sustained battery drain and consume 500 MB to 4 GB of RAM. Apple Mail provides native speed but lacks Gmail tag semantics (duplicating labeled emails into folder structures) and offers no GitHub workflow awareness, while web clients lack desktop shortcut responsiveness and offline snapshotting. Furthermore, existing AI coding workflows require developers to repeatedly switch contexts back to browser tabs when terminal-based coding agents prompt them for reproduction steps, issue descriptions, or comment threads.

---

### Findings

#### 1. Severity: 🔴 Blocker
* **Affected Scope:** `Technical Plan > 2. Core Components and Subsystems > B. Synchronization Engine` (lines 135–139) & `Detailed Implementation Plan > 6. GmailService.swift` (lines 331–339).
* **Discrepancy Description & Rationale:** Initial inbox bootstrap and full reconciliation are not implementable with the declared APIs. The document specifies that Gmail sync bootstraps by fetching `historyId` via `users.getProfile` and polling `users.history.list`. However, `users.history.list` only returns delta mutations that occur *after* the provided `historyId`. On a fresh cold start with no local snapshot, polling `users.history.list` with the baseline profile `historyId` returns zero existing messages. Furthermore, line 139 states that on HTTP 404 (`INVALID_HISTORY_ID`), the engine "executes a full reconciliation fetch of the inbox," but `GmailService.swift` omits any method to list inbox messages (such as `users.messages.list(q: "label:INBOX")` or `users.threads.list`). Without an initial inbox list endpoint, fresh installs will display empty inboxes and stale history recovery will fail.

#### 2. Severity: 🔴 Blocker
* **Affected Scope:** `Technical Plan > 2. Core Components and Subsystems > E. AgentDispatchService` (lines 169–185), `Data Schema and Domain Model` (lines 198–241), `Detailed Implementation Plan > 7. GitHubService.swift` (lines 340–346), & `14. DetailPaneView.swift` (lines 371–374).
* **Discrepancy Description & Rationale:** Missing data pipeline and endpoints for GitHub issue bodies and comment timelines. The core CUJ 3 and `AgentDispatchService` require extracting the issue body, reproduction steps, and latest comments into `AgentDispatchPayload`, while `DetailPaneView` is expected to render a "full comment timeline." However:
  1. `TriageItem` contains no fields for an issue/PR body or comments.
  2. `TriageStore` only maintains arrays of `TriageItem`.
  3. `GitHubService.swift` defines only `fetchNotifications`, `batchFetchPRDetails`, and `dismissNotification`, completely lacking any REST or GraphQL query method to fetch issue descriptions or discussion comments.
  The design provides no explanation or data model for where, when, or how issue bodies and comments are retrieved and cached.

#### 3. Severity: 🟡 Major
* **Affected Scope:** `Technical Plan > 2. Core Components and Subsystems > E. AgentDispatchService` (lines 183–184), `Alternatives Considered > Alternative E` (lines 271–275), & `Non-Functional Requirements > 2. Security & Privacy` (lines 292–295).
* **Discrepancy Description & Rationale:** Incompatible sandbox permissions for launching external terminal commands. Non-functional requirements mandate enabling the macOS App Sandbox (`com.apple.security.app-sandbox`) with only `network.client` enabled. However, `AgentDispatchService` is expected to launch terminal emulators (Terminal.app, iTerm2, Ghostty) and execute CLI commands with arguments. Under macOS App Sandbox, calling `NSWorkspace.shared.openApplication` cannot inject shell execution strings or scripts into external terminal emulators without Apple Events / AppleScript scripting bridge permissions (`com.apple.security.temporary-exception.apple-events` for target bundle IDs). The design claims sandbox compliance as an advantage over Alternative E without defining the required entitlements or mechanism to pass commands into third-party terminal apps.

#### 4. Severity: 🟡 Major
* **Affected Scope:** `Technical Plan > 2. Core Components and Subsystems > E. AgentDispatchService` (lines 173, 183) & `Detailed Implementation Plan` (lines 305–378).
* **Discrepancy Description & Rationale:** Missing persistence model and configuration UI for user preferences and repository mapping. Line 173 states the local Git path is "mapped via user preferences by repository name," and line 183 refers to the "user's configured terminal emulator." Meanwhile, line 131 establishes a strict invariant: "No tokens are saved in `UserDefaults`, plists, or plaintext" (storing only credentials in the Keychain). There is no data model, settings store, configuration file, or settings UI declared in the architecture or the target file list to manage repository path mappings, terminal app selections, or CLI agent preferences.

#### 5. Severity: 🟡 Major
* **Affected Scope:** `Technical Plan > 2. Core Components and Subsystems > A. AuthService` (lines 128–132) & `Verification Plan` (line 408).
* **Discrepancy Description & Rationale:** Unstated GitHub OAuth authentication mechanism and PKCE mismatch. The document states that OAuth 2.0 PKCE (`S256`) is used for both Gmail and GitHub ("standard OAuth application flow for GitHub"). However, GitHub's standard OAuth App authorization code grant does not support PKCE; exchanging the temporary code for an access token requires a client secret (`client_secret`), which cannot be securely embedded in a sandboxed public desktop client without a backend proxy or utilizing GitHub Device Authorization Flow (RFC 8628) / Personal Access Tokens. Additionally, while the verification plan mentions supplying a personal Google Cloud Client ID (line 408), it is completely silent on how GitHub application credentials or tokens are provided or configured.

#### 6. Severity: 🟡 Major
* **Affected Scope:** `Technical Plan > 2. Core Components and Subsystems > A. AuthService` (line 130).
* **Discrepancy Description & Rationale:** Undefined local loopback listener for `http://127.0.0.1:0/callback`. The document states that `ASWebAuthenticationSession` uses a loopback redirect URI targeting port `0` (`http://127.0.0.1:0/callback`). `ASWebAuthenticationSession` natively intercepts custom URL schemes (e.g., `devtriage://callback`). Redirecting to loopback HTTP on an ephemeral port (`:0`) requires binding an active local TCP/HTTP server socket to receive the incoming redirect and extract the authorization code. The document specifies zero external dependencies and does not include an in-app local HTTP listener component to capture this callback.

#### 7. Severity: 🟢 Nit
* **Affected Scope:** `Goals` (line 31), `High-Level System Architecture` (line 103), & `Detailed Implementation Plan > 4. TriageStore.swift` (lines 321–325).
* **Discrepancy Description & Rationale:** Incomplete definition of the trash shortcut (`#`/`Delete`). The document references `#`/`Delete` as a core keyboard shortcut for trashing items, but neither `TriageStore.swift`, `GmailService.swift`, nor `GitHubService.swift` implement a trash action. It is undefined whether trashing applies to GitHub items (e.g., unsubscribe/delete notification) or is restricted to Gmail (`users.messages.trash`).

#### 8. Severity: 🟢 Nit
* **Affected Scope:** `Detailed Implementation Plan > 6. GmailService.swift` (line 338) vs. `Technical Plan > 2. Core Components and Subsystems > C. TriageStore` (line 154).
* **Discrepancy Description & Rationale:** Mismatched thread vs. message archive API. Line 338 specifies `archiveThread(id: String): Removes INBOX label via users.messages.modify`. In the Gmail REST API, `users.messages.modify` modifies a single message ID; modifying a whole thread requires `users.threads.modify`. Calling `messages.modify` on a thread ID or a single message in a thread risks leaving other messages from that thread in the inbox.

#### 9. Severity: 🟢 Nit
* **Affected Scope:** `Goals` (line 32) & `Alternatives Considered > Alternative E` (line 275).
* **Discrepancy Description & Rationale:** Ambiguous terminology regarding "CLI subscriptions." The phrases "using existing CLI subscriptions" and "preserving existing agent subscriptions" conflate user account billing/subscriptions with technical event subscriptions. Specifying "existing local user CLI tool installations and accounts" would prevent confusion.
