# Native macOS Developer Triage Client (Gmail & GitHub)

* **Author:** Antigravity & User
* **Status:** Proposed
* **Date:** 2026-11-03

--------------------------------------------------------------------------------

## Overview

This document specifies the technical design for a lightweight, native macOS desktop client built in Swift 6 and SwiftUI. The application provides a focused, high-density triage interface for personal Gmail inboxes and GitHub notifications (assigned issues, pull request review requests, and CI failures). 

By operating directly against the Gmail REST API and GitHub REST/GraphQL APIs without containerization (no Docker) or browser runtimes (no Electron), the application achieves sub-50ms keyboard interaction latency and maintains an idle memory footprint under 50 MB. It bridges the developer workflow by coupling fast triage shortcuts with a 1-click context dispatch mechanism for local CLI coding agents (Claude Code, OpenCode, Antigravity) while keeping issue details pinned side-by-side for reference.

--------------------------------------------------------------------------------

## The Problem

Software developers handle two continuous streams of asynchronous communication: personal/work email and GitHub activity (code reviews, issue assignments, CI alerts). Current solutions fail developers in distinct ways:

1. **Memory and Battery Overhead:** Open-source desktop clients and developer notification aggregators frequently package WebKit/Chromium runtimes (Electron) or require background Docker containers running Linux VMs, consuming 500 MB to 4 GB of RAM and causing sustained laptop battery drain.
2. **Aesthetic and Functional Lag:** Apple Mail offers native performance but presents outdated visuals, lacks Gmail-native tag semantics (modeling labels as duplicated folders), and offers zero integration with GitHub workflows. Gmail web lacks global macOS desktop integration, native keyboard responsiveness, and offline snapshot resilience.
3. **Fragmented AI Agent Workflow:** When developers dispatch GitHub issues to local CLI coding agents in their terminal, the agent frequently asks clarifying questions regarding reproduction steps, edge cases, or existing comments. Developers are forced to switch contexts back to a browser tab to retrieve this information, interrupting development flow.

--------------------------------------------------------------------------------

## Goals

* **Sub-50ms Native macOS Triage:** Deliver immediate UI response for all triage actions using native Swift 6, SwiftUI `NavigationSplitView`, and San Francisco typography.
* **Stream Isolation:** Provide two dedicated sidebar workspaces—**Gmail** (inbox triage, label management) and **GitHub** (issues, pull requests, CI alerts)—preventing cross-stream clutter.
* **Safe Keyboard Navigation:** Provide Vim/Superhuman-style single-key shortcuts (`j`/`k` navigate, `e` archive/dismiss, `s` star, `#`/`Delete` trash, `u` unread). Local triage dismissal (`e`) must never alter public GitHub repository state.
* **Context-Preserving Agent Dispatch:** Provide a 1-click or keyboard shortcut (`Cmd+Shift+A`) that bundles full issue metadata into a structured prompt, launches the user's local terminal/agent CLI using existing CLI subscriptions, and keeps the issue detail pane pinned for reference.
* **Minimal Resource Footprint:** Maintain an idle memory footprint below 50 MB with zero Docker dependencies, no persistent background daemons, and zero CPU wakeups during macOS system sleep.
* **Secure Local Credentials:** Store all OAuth 2.0 PKCE access and refresh tokens exclusively in the macOS Keychain (`Security.framework`).

--------------------------------------------------------------------------------

## Non-Goals

* **Email Composition and Rich-Text Authoring:** No drafting, WYSIWYG editor, or reply functionality in v1 (read-and-triage only).
* **Embedded Terminal Emulator:** The application will not embed a pseudo-terminal (PTY) runner, ANSI parser, or interactive shell runner inside the app bundle.
* **Heavy Offline Relational Sync:** No multi-gigabyte local SQLite cache of historical message archives or large attachments.
* **Multi-Provider Email / Git Support:** No generic IMAP/POP3, Microsoft Exchange, GitLab, or Bitbucket support.
* **Comprehensive Project Management:** No Kanban boards, milestone roadmaps, or issue creation workflows.

--------------------------------------------------------------------------------

## Open Questions

None currently open. The choices regarding stream isolation, archive hotkey safety invariants, and out-of-process agent dispatch were resolved during ideation.

--------------------------------------------------------------------------------

## Critical User Journeys (CUJs)

### CUJ 1: Morning Gmail Inbox Triage
* **Given:** The user has 45 unread emails in their Gmail inbox. The app was closed overnight.
* **When:** The user launches the application and selects the Gmail workspace.
* **Then:** The app immediately displays the cached snapshot from the previous session while `SyncCoordinator` performs an incremental poll via `users.history.list`. The user processes the inbox using `j`/`k` and presses `e` on unwanted threads, removing the `INBOX` label on Gmail servers with optimistic local UI removal (<16ms).

### CUJ 2: CI Failure & Review Request Triage
* **Given:** A pull request build failed on GitHub, generating a notification with reason `ci_activity`.
* **When:** The user switches to the GitHub workspace.
* **Then:** The item appears hoisted under the "CI Alerts" smart filter. The user inspects the failed check summary in the native detail pane and presses `Cmd+O` to open the GitHub Actions run directly in their default browser, or `e` to dismiss the notification without closing the PR.

### CUJ 3: Dispatching an Issue to Local Coding Agent
* **Given:** An assigned GitHub issue requires a bug fix. The user has Claude Code, OpenCode, or Antigravity installed locally.
* **When:** The user selects the issue and presses `Cmd+Shift+A` (Dispatch to Agent).
* **Then:** The app formats the issue title, body, comments, reproduction details, and repository path into a structured prompt, launches the user's terminal running the local CLI agent, and leaves the issue detail pane visible side-by-side on macOS. When the agent asks questions in the terminal, the user reads the pinned context directly without switching apps.

--------------------------------------------------------------------------------

## Technical Plan (Architecture)

### 1. High-Level System Architecture

The application adopts a layered, reactive architecture built entirely with Swift 6 structured concurrency. State flows unidirectionally from isolated background actors through an observable store to the SwiftUI presentation tree.

```mermaid
flowchart TD
    subgraph UI ["Presentation Layer (SwiftUI / AppKit)"]
        SidebarView["SidebarView (NavigationSplitView)"]
        StreamView["TriageStreamView (LazyVStack / List)"]
        DetailView["DetailPaneView (SwiftUI + Recycled WKWebView)"]
        KeyHandler["KeyboardShortcutModifier (Vim/Superhuman)"]
    end

    subgraph State ["State & Coordination Layer"]
        TriageStore["TriageStore (@Observable @MainActor)"]
        SyncCoordinator["SyncCoordinator (Swift Actor)"]
        SnapshotManager["SnapshotManager (Disk JSON Cache)"]
        AgentDispatch["AgentDispatchService (Context Formatter & CLI Launcher)"]
    end

    subgraph Services ["External Network & Security Layer"]
        AuthService["AuthService (ASWebAuthenticationSession + Keychain)"]
        GmailService["GmailService (REST API + users.history.list)"]
        GitHubService["GitHubService (REST /notifications + GraphQL)"]
        PathMonitor["NWPathMonitor (Network Reachability)"]
        WorkspaceMonitor["NSWorkspace (Sleep / Wake Notifications)"]
    end

    KeyHandler -->|Triage Action (e / s / #)| TriageStore
    TriageStore --> StreamView
    StreamView --> DetailView
    SidebarView --> TriageStore

    TriageStore <-->|Load / Save Snapshot| SnapshotManager
    TriageStore <-->|Dispatch Trigger| AgentDispatch
    AgentDispatch -->|Launch Terminal / Agent CLI| ExternalTerminal["External Terminal / IDE"]

    SyncCoordinator -->|Update Observable State| TriageStore
    SyncCoordinator --> GmailService
    SyncCoordinator --> GitHubService
    SyncCoordinator --> AuthService

    PathMonitor --> SyncCoordinator
    WorkspaceMonitor --> SyncCoordinator
    AuthService --> Keychain["macOS Keychain (Security.framework)"]
    GmailService --> GmailAPI["Google Gmail REST API"]
    GitHubService --> GitHubAPI["GitHub REST & GraphQL API"]
```

---

### 2. Core Components and Subsystems

#### A. Auth & Token Management (`AuthService`)
* **Protocol & Transport:** OAuth 2.0 with Proof Key for Code Exchange (PKCE) using `S256` challenges.
* **Flow Execution:** Uses `ASWebAuthenticationSession` targeting loopback redirect URI (`http://127.0.0.1:0/callback`) for Gmail and standard OAuth application flow for GitHub.
* **Storage Invariant:** Access tokens, refresh tokens, and client configurations are stored exclusively in the macOS Keychain (`kSecClassGenericPassword`, accessible only when device is unlocked). No tokens are saved in `UserDefaults`, plists, or plaintext.

#### B. Synchronization Engine (`SyncCoordinator` Actor)
* **Actor Isolation:** `SyncCoordinator` runs on a private background executor, isolating all network polling, JSON deserialization, and state merging from the main thread.
* **Gmail Incremental Sync:**
  1. Bootstraps by reading `historyId` via `users.getProfile`.
  2. Runs periodic polling using `users.history.list(startHistoryId: historyId, labelId: "INBOX")`.
  3. Incremental payloads contain delta operations (`messagesAdded`, `labelsAdded`, `labelsRemoved`). Only mutated message IDs are fetched via `users.messages.get(format: .metadata)`.
  4. **Error Recovery Invariant:** When `users.history.list` returns HTTP 404 (`INVALID_HISTORY_ID`) due to long idle periods, the coordinator clears the stale `historyId` and executes a full reconciliation fetch of the inbox without throwing a fatal error.
* **GitHub Notification Polling:**
  1. Polls `/notifications` including the HTTP `If-None-Match` header holding the last known `ETag`.
  2. On HTTP 304 (`Not Modified`), zero rate limit quota is consumed and the polling cycle completes immediately.
  3. On HTTP 200, parses notification threads and issues a batched GraphQL query to resolve linked PR check statuses (`checkSuites`), author avatars, and comment counts.
* **System Lifecycle Integration:**
  * Subscribes to `NSWorkspace.willSleepNotification` to cancel pending poll timers before laptop sleep.
  * Subscribes to `NSWorkspace.didWakeNotification` to immediately trigger a sync cycle upon laptop wake.
  * Subscribes to `NWPathMonitor` to suspend polling during network loss and resume upon reconnection.
* **Polling Cadence:** Default 45-second timer with a ±5-second randomized jitter to avoid rhythmic network bursts.

#### C. In-Memory Store & Triage Model (`TriageStore`)
* **Architecture:** `@Observable @MainActor final class TriageStore`.
* **Collection Management:** Maintains separate arrays for `gmailItems` and `gitHubItems`. Bounded to a maximum of 500 items per stream using a Least-Recently-Updated eviction policy to cap memory footprint.
* **Optimistic Local Mutations:**
  * When `e` (archive) is pressed on an email, the item is removed immediately from the visible list and an asynchronous task calls `users.messages.modify(removeLabelIds: ["INBOX"])`.
  * If the network call fails after exponential backoff, the item is restored to the store and an unobtrusive notification bar appears.
  * For GitHub notifications, `e` marks the thread as read (`PATCH /notifications/threads/{id}`) without touching the public issue or PR state.
* **Snapshot Persistence:** On `NSApplication.willTerminateNotification`, writes an unencrypted JSON snapshot of the in-memory store to `~/Library/Application Support/DevTriage/snapshot.json`. On cold start, the snapshot renders immediately, preventing empty loading states.

#### D. Detail View & HTML Email Isolation (`DetailPaneView`)
* **Email Rendering:**
  * Uses a single, recycled `WKWebView` instance inside the detail pane to eliminate the memory overhead of spawning web views.
  * Configures `WKWebpagePreferences.allowsContentJavaScript = false` to eliminate XSS risks and script execution latency.
  * Rewrites HTML body to inject a localized CSS reset conforming to `prefers-color-scheme: dark`.
  * Blocks all external image URLs (`<img src="https://...">`) by default to prevent tracking beacons; loads images only when the user explicitly clicks "Load External Images".
  * Implements `WKNavigationDelegate.decidePolicyFor` to redirect all hyperlink clicks to `NSWorkspace.shared.open(url)` in the user's default browser.
* **GitHub Rendering:** Pure native SwiftUI text and markdown rendering utilizing `LocalizedStringKey` / `AttributedString`, zero web view allocation.

#### E. Local Coding Agent Dispatch (`AgentDispatchService`)
* **Context Assembly:** When triggered (`Cmd+Shift+A`), extracts:
  * Repository name, issue/PR number, and title.
  * Issue body text and reproduction steps.
  * Recent conversation comments and author handles.
  * Local Git working tree path (mapped via user preferences by repository name).
* **Execution Boundary:** Formats a structured markdown prompt:
  ```markdown
  Solve GitHub Issue #{number}: {title}
  Repository: {repo_name}
  Context:
  {body}
  Latest Comments:
  {comments}
  ```
* **Launch Trigger:** Uses `NSWorkspace.shared.openApplication` or terminal script to open the user's configured terminal emulator (Terminal.app, iTerm2, Ghostty) running their CLI agent (e.g. `claude`, `opencode`, `antigravity`) with the prompt passed via temporary file or command argument.
* **Side-by-Side Invariant:** The desktop app keeps the issue view pinned in the detail pane so that when the agent prompts the user in the terminal, the reference context is directly visible.

---

### 3. Data Schema and Domain Model

```swift
import Foundation

enum TriageSource: String, Codable, Sendable, Hashable {
    case gmail
    case gitHub
}

enum TriageKind: Codable, Sendable, Hashable {
    case email(threadId: String, snippet: String, hasHtml: Bool)
    case gitHubIssue(number: Int, repo: String, state: String, isAssignedToMe: Bool)
    case gitHubPullRequest(number: Int, repo: String, isDraft: Bool, reviewStatus: String, ciStatus: String)
    case gitHubNotification(threadId: String, reason: String)
}

struct TriageItem: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let source: TriageSource
    let title: String
    let authorName: String
    let authorAvatarURL: URL?
    let timestamp: Date
    var isUnread: Bool
    var isStarred: Bool
    var isArchived: Bool
    let tags: [String]
    let kind: TriageKind
    let webURL: URL
}

struct AgentDispatchPayload: Sendable {
    let issueNumber: Int
    let repository: String
    let title: String
    let body: String
    let comments: [String]
    let localRepoPath: URL?
    
    var formattedPrompt: String {
        """
        # Task: Address GitHub Issue #\(issueNumber) in \(repository)
        Title: \(title)
        
        ## Description
        \(body)
        
        ## Comments
        \(comments.joined(separator: "\n\n---\n\n"))
        """
    }
}
```

--------------------------------------------------------------------------------

## Alternatives Considered

### Alternative A: IMAP with Gmail Extensions (`X-GM-EXT-1`)

* **Pros:** Standardized protocol across mail servers; supports instant server-push notifications over persistent TCP sockets via `IMAP IDLE` without third-party webhook infrastructure.
* **Cons:** IMAP models tags as folders. In Gmail, an email with multiple labels appears in multiple IMAP folders; archiving requires copying the message to `[Gmail]/All Mail` and expunging it from `INBOX`, causing synchronization duplication and bandwidth waste. `IMAP IDLE` connections drop frequently during macOS Wi-Fi transitions, requiring complex socket recovery logic.
* **Reason for Rejection:** The Gmail REST API natively represents labels as metadata tags on threads, allowing archiving via a single atomic `removeLabelIds: ["INBOX"]` request.

### Alternative B: Docker-Based Background Sync Engine (e.g., Nylas or Mailspring Architecture)

* **Pros:** Runs a continuous 24/7 background worker to index messages; offloads database operations and search indexing to dedicated container services (e.g., Redis, SQLite daemon).
* **Cons:** Requires installing and maintaining Docker Desktop on macOS. Docker runs an entire Linux hypervisor VM, routinely consuming 2 to 4 GB of RAM and causing continuous background battery drain on MacBooks. Creates severe onboarding friction and port conflict issues.
* **Reason for Rejection:** Directly violates the user requirement for a bloat-free, simple desktop client. A pure Swift 6 native application runs in 30–50 MB of RAM with zero container dependencies.

### Alternative C: Web-Wrapped Framework (Electron or Tauri)

* **Pros:** Rapid multi-platform UI iteration using web technologies (HTML, CSS, React); easy DOM-based email rendering.
* **Cons:** Electron packages a full Chromium browser and Node runtime, consuming 500 MB to 2 GB of RAM and feeling sluggish compared to native AppKit/SwiftUI controls. While Tauri uses the system webview, managing multi-process IPC and secure sandboxing between untrusted email HTML and the application shell introduces non-trivial security overhead.
* **Reason for Rejection:** Fails the responsiveness and aesthetics requirements. Native SwiftUI delivers sub-50ms interaction latency and authentic macOS typography and split-view behaviors.

### Alternative D: Full Local Relational Database Cache (SQLite / CoreData)

* **Pros:** Enables full offline browsing of multi-gigabyte historical email archives and complex offline search queries.
* **Cons:** Introduces schema migration burdens, disk lock contention, database corruption risks, and extensive two-way synchronization reconciliation code.
* **Reason for Rejection:** Unnecessary for an inbox triage tool. Triage focuses on recent unread mail and active notifications. An in-memory observable store capped at 500 items, paired with an ephemeral JSON snapshot saved on app quit, provides instantaneous cold starts without database synchronization complexity.

### Alternative E: Embedded Terminal Emulator for Local AI Agents

* **Pros:** Keeps all coding agent interactions inside the desktop app window.
* **Cons:** Requires implementing a full pseudo-terminal (PTY) runner, ANSI escape code parsing, terminal window resizing, and shell input piping. Requires disabling macOS App Sandbox (`com.apple.security.app-sandbox`), exposing the app to security risks and adding thousands of lines of maintenance overhead.
* **Reason for Rejection:** The low-bloat context dispatch pattern (`Cmd+Shift+A`) formats the issue details and launches the user's existing terminal/agent CLI in one keystroke, preserving existing agent subscriptions while keeping the issue detail pane pinned side-by-side for reference.

### Alternative F: Merged Single Stream (Gmail + GitHub Combined)

* **Pros:** One unified inbox feed for all asynchronous notifications.
* **Cons:** Causes cognitive confusion by interweaving personal correspondence with automated CI alerts and code review pings. Requires complex, brittle heuristics to deduplicate GitHub notification emails from GitHub API events.
* **Reason for Rejection:** Dedicated sidebar workspaces provide clean mental separation of concerns.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### 1. Performance & Resource Footprint
* **Memory Budget:** Idle resident set size (RSS) must remain strictly under 50 MB. When `WKWebView` renders complex HTML emails, memory usage must not exceed 90 MB and must return to base levels upon switching to GitHub markdown views.
* **Latency:** Keyboard navigation (`j`/`k`) and optimistic triage state updates (`e`, `s`) must complete within 16 milliseconds (60 fps frame budget). Cold start from snapshot to interactive UI must complete under 100 milliseconds.
* **Battery & Power:** Zero background CPU usage during macOS App Nap or system sleep. Polling strictly suspended during sleep states.

### 2. Security & Privacy
* **App Sandbox:** Configured with `com.apple.security.app-sandbox` and `com.apple.security.network.client`. Outgoing network traffic restricted to `googleapis.com` and `github.com`.
* **Keychain Storage:** All OAuth tokens (access and refresh) stored in macOS Keychain with access control set to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
* **WebKit Isolation:** `WKWebView` runs with `allowsContentJavaScript = false`. Remote image assets blocked by default to eliminate tracking beacons. Outbound link clicks routed exclusively to `NSWorkspace.shared.open`.

### 3. Reliability & Rollout
* **Network Partition Tolerance:** Network disconnection pauses polling gracefully without user-facing alert modals. Reconnection automatically triggers an immediate sync refresh.
* **Stale History Invalidation:** Handles Gmail HTTP 404 `INVALID_HISTORY_ID` by automatically falling back to full reconciliation without corrupting in-memory state.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Target Files to Create/Modify

#### 1. `Package.swift` (Create)
* **Type / Scope:** Swift Package Manager Build Manifest
* **Proposed Changes:** Defines the `DevTriage` executable target with macOS 14+ minimum deployment target. Uses Swift 6 language mode. Zero external third-party package dependencies. Declares dependencies strictly on Apple standard frameworks (`Foundation`, `SwiftUI`, `AuthenticationServices`, `WebKit`, `Security`, `Network`).

#### 2. `Sources/DevTriage/App/DevTriageApp.swift` (Create)
* **Type / Scope:** Application Entrypoint & Lifecycle
* **Proposed Changes:** `@main struct DevTriageApp: App`. Configures main `WindowGroup` with default window dimensions (1100x700), instantiates the root `@State private var store = TriageStore()`, and coordinates application termination notifications to save the cold-start snapshot.

#### 3. `Sources/DevTriage/Models/TriageItem.swift` (Create)
* **Type / Scope:** Core Domain Entities
* **Proposed Changes:** Defines `TriageSource` (`gmail`, `gitHub`), `TriageKind` (distinguishing emails, issues, PRs, and notifications), and `TriageItem` (`Identifiable`, `Codable`, `Sendable`, `Hashable`). Defines `AgentDispatchPayload` with formatted markdown compilation logic for CLI agents.

#### 4. `Sources/DevTriage/State/TriageStore.swift` (Create)
* **Type / Scope:** Observable Presentation State
* **Proposed Changes:** `@Observable @MainActor final class TriageStore`. Maintains `gmailItems` and `gitHubItems` arrays, active stream filter, and selected item ID. Implements optimistic actions:
  - `archive(item:)`: Removes item locally and dispatches network call (`removeLabelIds: ["INBOX"]` or `PATCH /notifications/threads/{id}`).
  - `star(item:)`: Toggles starred state locally and remotely.
  - `markUnread(item:)`: Toggles unread state.
  - Enforces 500-item LRU capacity bound to cap memory footprint. Handles network failure rollback with user-facing undo toast.

#### 5. `Sources/DevTriage/Services/AuthService.swift` (Create)
* **Type / Scope:** OAuth 2.0 PKCE & Keychain Wrapper
* **Proposed Changes:** Implements `ASWebAuthenticationSession` with ephemeral presentation context. Generates cryptographically secure `code_verifier` and `code_challenge` (S256). Provides strongly typed CRUD operations for macOS Keychain using `Security.framework` (`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`) with device-unlocked protection.

#### 6. `Sources/DevTriage/Services/GmailService.swift` (Create)
* **Type / Scope:** Google Gmail REST API Engine
* **Proposed Changes:** Client conforming to `Sendable`. Implements:
  - `getProfile()`: Retrieves user email and baseline `historyId`.
  - `fetchHistory(since: String)`: Incremental polling via `users.history.list`. Detects HTTP 404 `INVALID_HISTORY_ID` and triggers clean full reconciliation.
  - `fetchMessageMetadata(ids: [String])`: Batched metadata fetching for list rendering.
  - `fetchMessageBody(id: String)`: Full MIME parsing (base64url decoding, multipart/alternative extraction of sanitized HTML).
  - `archiveThread(id: String)`: Removes `INBOX` label via `users.messages.modify`.

#### 7. `Sources/DevTriage/Services/GitHubService.swift` (Create)
* **Type / Scope:** GitHub REST & GraphQL Engine
* **Proposed Changes:** Client conforming to `Sendable`. Implements:
  - `fetchNotifications(lastETag: String?)`: Polls `/notifications` with `If-None-Match`. Returns `.notModified` on HTTP 304, consuming zero quota.
  - `batchFetchPRDetails(prUrls: [URL])`: Batched GraphQL queries for CI check suite status and PR review states.
  - `dismissNotification(threadId: String)`: Executes `PATCH /notifications/threads/{threadId}`.

#### 8. `Sources/DevTriage/Services/SyncCoordinator.swift` (Create)
* **Type / Scope:** Concurrency & Background Polling Actor
* **Proposed Changes:** Swift `actor` orchestrating polling cycles. Runs continuous 45s (±5s) timer loop. Subscribes to `NWPathMonitor` for connection status and `NSWorkspace.willSleepNotification` / `didWakeNotification` to suspend during sleep and perform instant wake updates. Dispatches fresh items to `TriageStore` on `@MainActor`.

#### 9. `Sources/DevTriage/Services/SnapshotManager.swift` (Create)
* **Type / Scope:** Local Cold-Start Persistence
* **Proposed Changes:** Asynchronously writes in-memory triage items to `~/Library/Application Support/DevTriage/snapshot.json` on app quit. Reads and parses snapshot on launch in under 50ms before network connections initialize.

#### 10. `Sources/DevTriage/Services/AgentDispatchService.swift` (Create)
* **Type / Scope:** CLI Coding Agent Context Dispatcher
* **Proposed Changes:** Extracts issue/PR details, formats structured markdown instructions, and launches the user's configured terminal emulator (Terminal, iTerm2, Ghostty) running their CLI agent (`claude`, `opencode`, `antigravity`). Pins the issue view in `DetailPaneView` for simultaneous side-by-side reading.

#### 11. `Sources/DevTriage/Views/MainSplitView.swift` (Create)
* **Type / Scope:** 3-Column Root View Layout
* **Proposed Changes:** `NavigationSplitView` hosting `SidebarView`, `TriageStreamView`, and `DetailPaneView`. Installs `.keyboardShortcut` modifiers for Vim/Superhuman single-key hotkeys (`j`/`k`, `e`, `s`, `u`, `Cmd+Shift+A`, `Cmd+O`).

#### 12. `Sources/DevTriage/Views/SidebarView.swift` (Create)
* **Type / Scope:** Navigation Sidebar
* **Proposed Changes:** Workspace selection buttons for **Gmail** and **GitHub** with unread count pills. Smart filter sections for GitHub: `CI Alerts` (failures), `Mentions`, and `Review Requests`.

#### 13. `Sources/DevTriage/Views/TriageStreamView.swift` (Create)
* **Type / Scope:** Virtualized Item List
* **Proposed Changes:** Dense list view displaying `TriageItem` rows with unread indicators, relative dates, author avatars, title, two-line snippet, and status badges.

#### 14. `Sources/DevTriage/Views/DetailPaneView.swift` (Create)
* **Type / Scope:** Detail Inspector Pane
* **Proposed Changes:** Conditionally displays `RecycledWKWebView` for Gmail messages or native SwiftUI markdown view for GitHub issues. Displays issue header, state pills, action bar with "Dispatch to Agent" button (`Cmd+Shift+A`), and full comment timeline.

#### 15. `Sources/DevTriage/Views/Components/RecycledWKWebView.swift` (Create)
* **Type / Scope:** Sandboxed AppKit WebKit Wrapper
* **Proposed Changes:** `NSViewRepresentable` managing a single reusable `WKWebView`. Disables JavaScript (`allowsContentJavaScript = false`), injects dark-mode CSS overrides, blocks remote image URLs by default with a "Load Images" button, and intercepts link clicks via `decidePolicyFor` to open in external browser.

#### 16. `Tests/DevTriageTests/SyncCoordinatorTests.swift` (Create)
* **Type / Scope:** Synchronization Concurrency Unit Tests
* **Proposed Changes:** Validates incremental polling, ETag caching (304), network interruption recovery, and HTTP 404 `INVALID_HISTORY_ID` recovery logic using mock `URLProtocol`.

#### 17. `Tests/DevTriageTests/TriageStoreTests.swift` (Create)
* **Type / Scope:** State & Optimistic Mutation Tests
* **Proposed Changes:** Validates 500-item LRU eviction, optimistic archive deletion with rollback on simulated network failure, and snapshot serialization/deserialization.

#### 18. `Tests/DevTriageTests/AgentDispatchTests.swift` (Create)
* **Type / Scope:** Agent Context Assembly Tests
* **Proposed Changes:** Validates markdown prompt generation from issues and PR comments, verifying sanitization and file path resolution.

---

### Verification Plan

* **Compilation/Build:**
  * Clean build via Swift Package Manager: `swift build -c release`
  * Verify zero compiler warnings under Swift 6 language mode (`-swift-version 6`).
* **Unit Tests:**
  * Execute test suite: `swift test`
  * Verify 100% pass rate across state machine, LRU eviction, ETag 304 parsing, and Keychain mocking.
* **Static Analysis & Linting:**
  * Run `swift format lint --strict` and `swiftlint` (if installed).
  * Validate App Sandbox entitlements using `codesign -d --entitlements :- .build/release/DevTriage`.
* **Resource Benchmarking:**
  * Validate memory footprint in macOS Instruments / Activity Monitor: verify idle RSS < 50 MB, detail pane WebKit peak < 90 MB.
  * Validate 0.0% CPU usage while window is closed or system is asleep.
* **Manual Critical User Journey Verification:**
  * Validate OAuth login flow with personal Google Cloud Client ID.
  * Validate `j`/`k` list traversal and `e` keyboard archiving against live Gmail inbox.
  * Validate `Cmd+Shift+A` context dispatch opening terminal with formatted issue prompt.

--------------------------------------------------------------------------------

*Drafted with EGM*
