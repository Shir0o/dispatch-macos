# Native macOS Developer Triage Client (Gmail & GitHub)

* **Author:** Antigravity & User
* **Status:** Accepted
* **Date:** 2026-11-03

--------------------------------------------------------------------------------

## Overview

This document specifies the technical design for a lightweight, native macOS desktop client built in Swift 6 and SwiftUI. The application provides a focused, high-density triage interface for personal Gmail inboxes and GitHub notifications (assigned issues, pull request review requests, and CI failures). 

By operating directly against the Gmail REST API and GitHub REST API v3 without containerization (no Docker) or browser runtimes (no Electron), the application achieves sub-50ms keyboard interaction latency and maintains an idle memory footprint under 50 MB. It bridges the developer workflow by coupling fast triage shortcuts with a 1-click clipboard context dispatch mechanism for local CLI coding agents (Claude Code, OpenCode, Antigravity) while keeping issue details pinned side-by-side for reference.

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
* **Safe Keyboard Navigation:** Provide Vim/Superhuman-style single-key shortcuts (`j`/`k` navigate, `e` archive/dismiss, `s` star, `#`/`Delete` trash, `u` unread). Local triage dismissal (`e`) must never alter public GitHub repository state. Single-key shortcuts are guarded against active text inputs via `@FocusState`.
* **Context-Preserving Agent Dispatch:** Provide a 1-click or keyboard shortcut (`Cmd+Shift+A`) that formats full issue metadata into a structured markdown prompt on `NSPasteboard.general`, triggers a 1.5-second transient toast, activates the user's configured terminal/IDE, and keeps the issue detail pane pinned for reference.
* **Minimal Resource Footprint:** Maintain an idle memory footprint below 50 MB with zero Docker dependencies, no persistent background daemons, and zero CPU wakeups during macOS system sleep.
* **Secure Local Credentials:** Store OAuth tokens and GitHub Personal Access Tokens (PAT) exclusively in the macOS Keychain (`Security.framework`) with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

--------------------------------------------------------------------------------

## Non-Goals

* **Email Composition and Rich-Text Authoring:** No drafting, WYSIWYG editor, or reply functionality in v1 (read-and-triage only).
* **Embedded Terminal Emulator:** The application will not embed a pseudo-terminal (PTY) runner, ANSI parser, or interactive shell runner inside the app bundle.
* **Heavy Offline Relational Sync:** No multi-gigabyte local SQLite cache of historical message archives or large attachments.
* **Multi-Provider Email / Git Support:** No generic IMAP/POP3, Microsoft Exchange, GitLab, or Bitbucket support.
* **Comprehensive Project Management:** No Kanban boards, milestone roadmaps, or issue creation workflows.

--------------------------------------------------------------------------------

## Open Questions

None currently open. The choices regarding stream isolation, archive hotkey safety invariants, and out-of-process clipboard agent dispatch were resolved during ideation and review.

--------------------------------------------------------------------------------

## Critical User Journeys (CUJs)

### CUJ 1: Morning Gmail Inbox Triage
* **Given:** The user has 45 unread emails in their Gmail inbox. The app was closed overnight.
* **When:** The user launches the application and selects the Gmail workspace.
* **Then:** The app immediately displays the cached snapshot from the previous session while `SyncCoordinator` performs an incremental poll via `users.history.list` (or `users.threads.list(q: "label:INBOX")` if cold). The user processes the inbox using `j`/`k` and presses `e` on unwanted threads, removing the `INBOX` label on Gmail servers via `users.threads.modify` with optimistic local UI removal (<16ms).

### CUJ 2: CI Failure & Review Request Triage
* **Given:** A pull request build failed on GitHub, generating a notification with reason `ci_activity`.
* **When:** The user switches to the GitHub workspace.
* **Then:** The item appears hoisted under the "CI Alerts" smart filter. The user inspects the failed check summary in the native detail pane (fetched via `/repos/{owner}/{repo}/commits/{ref}/check-runs`) and presses `Cmd+O` to open the GitHub Actions run directly in their default browser, or `e` to dismiss the notification without closing the PR.

### CUJ 3: Dispatching an Issue to Local Coding Agent
* **Given:** An assigned GitHub issue requires a bug fix. The user has Claude Code, OpenCode, or Antigravity installed locally.
* **When:** The user selects the issue and presses `Cmd+Shift+A` (Dispatch to Agent).
* **Then:** The app formats the issue title, body, comments, reproduction details, and repository path into a structured markdown prompt, writes it to `NSPasteboard.general`, displays a 1.5s toast ("Issue prompt copied to clipboard"), and activates the user's terminal emulator or IDE (`NSWorkspace.shared.openApplication`). The issue detail pane remains visible side-by-side on macOS for reference.

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
        SettingsView["SettingsView (Accounts & Dispatch Prefs)"]
        KeyHandler["KeyboardShortcutModifier (Vim/Superhuman + FocusGuard)"]
    end

    subgraph State ["State & Coordination Layer"]
        PreferencesStore["PreferencesStore (@Observable)"]
        TriageStore["TriageStore (@Observable @MainActor)"]
        SyncCoordinator["SyncCoordinator (Swift Actor)"]
        AgentDispatch["AgentDispatchService (Clipboard & App Activator)"]
    end

    subgraph Services ["External Network & Security Layer"]
        AuthService["AuthService (ASWebAuthenticationSession + Keychain)"]
        GmailService["GmailService (REST API + users.threads)"]
        GitHubService["GitHubService (REST API v3 /notifications & /check-runs)"]
        PathMonitor["NWPathMonitor (Network Reachability)"]
        WorkspaceMonitor["NSWorkspace (Sleep / Wake Notifications)"]
    end

    KeyHandler -->|Triage Action (e / s / #)| TriageStore
    TriageStore --> StreamView
    StreamView --> DetailView
    SidebarView --> TriageStore
    SettingsView --> PreferencesStore

    TriageStore <-->|Load / Save Snapshot (Atomic Synchronous)| DiskStorage["~/Library/Application Support/DevTriage/snapshot.json"]
    TriageStore -->|Optimistic Archive / Star / Trash| GmailService
    TriageStore -->|Optimistic Dismiss / Unsubscribe| GitHubService
    TriageStore <-->|Dispatch Trigger| AgentDispatch
    AgentDispatch -->|Copy Prompt| Pasteboard["NSPasteboard.general"]
    AgentDispatch -->|Activate App| ExternalTerminal["External Terminal / IDE"]

    SyncCoordinator -->|Deliver Polled Items| TriageStore
    SyncCoordinator --> GmailService
    SyncCoordinator --> GitHubService
    SyncCoordinator --> AuthService

    PathMonitor --> SyncCoordinator
    WorkspaceMonitor --> SyncCoordinator
    AuthService --> Keychain["macOS Keychain (Security.framework)"]
    GmailService --> GmailAPI["Google Gmail REST API"]
    GitHubService --> GitHubAPI["GitHub REST API v3"]
```

---

### 2. Core Components and Subsystems

#### A. Auth & Token Management (`AuthService`)
* **Google Gmail OAuth 2.0:**
  * Uses `ASWebAuthenticationSession` with Proof Key for Code Exchange (PKCE, `S256`).
  * Target redirect URI: Custom reverse-DNS scheme `com.googleusercontent.apps.<client-id>:/oauth2redirect`, registered in `Info.plist`. This eliminates local TCP loopback sockets (`127.0.0.1:0`), fully complying with App Sandbox restrictions.
* **GitHub Authentication:**
  * Uses a GitHub Personal Access Token (PAT) with `repo` and `notifications` scopes configured in `SettingsView`. GitHub standard OAuth does not support PKCE for public native clients without embedded client secrets; PAT entry provides secure, sandboxed access without credential leaks.
* **Storage Invariant:** Access tokens, refresh tokens, and GitHub PATs are stored exclusively in the macOS Keychain (`kSecClassGenericPassword`, accessible with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).

#### B. Synchronization Engine (`SyncCoordinator` Actor)
* **Actor Isolation:** `SyncCoordinator` runs on a private background executor, isolating all network polling, JSON deserialization, and state merging from the main thread.
* **Gmail Incremental & Bootstrap Sync:**
  1. **Initial Bootstrap & Cold Reconcile:** Calls `fetchInboxThreads(pageToken:)` via `users.threads.list(q: "label:INBOX")`. Fetches thread objects containing initial message lists and stores the current `historyId` retrieved from `users.getProfile`.
  2. **Incremental Polling:** Runs periodic polling using `users.history.list(startHistoryId: historyId, labelId: "INBOX")`. Only mutated threads are refreshed.
  3. **Error Recovery Invariant:** When `users.history.list` returns HTTP 404 (`INVALID_HISTORY_ID`) due to long idle periods, the coordinator clears the stale `historyId` and immediately re-executes `users.threads.list(q: "label:INBOX")` full reconciliation without throwing a fatal error.
* **GitHub Notification Polling (Strict REST v3):**
  1. Polls `/notifications` including the HTTP `If-None-Match` header holding the last known `ETag`.
  2. On HTTP 304 (`Not Modified`), zero rate limit quota is consumed and the polling cycle completes immediately.
  3. On HTTP 200, parses notification threads. For pull request review and CI notifications, queries `/repos/{owner}/{repo}/commits/{ref}/check-runs` via REST v3 on demand to determine CI check suite status.
* **System Lifecycle Integration:**
  * Subscribes to `NSWorkspace.willSleepNotification` to cancel pending poll timers before laptop sleep.
  * Subscribes to `NSWorkspace.didWakeNotification` to immediately trigger a sync cycle upon laptop wake.
  * Subscribes to `NWPathMonitor` to suspend polling during network loss and resume upon reconnection.
* **Polling Cadence:** Fixed 45-second polling interval using structured `Task.sleep(for: .seconds(45))`.

#### C. In-Memory Store & Triage Model (`TriageStore`)
* **Architecture:** `@Observable @MainActor final class TriageStore`. Instantiated at the root composition root (`DevTriageApp.swift`) and injected into the environment.
* **Collection Management:** Maintains separate arrays for `gmailItems` and `gitHubItems`. Bounded to a maximum of 500 items per stream using simple array prefix slicing (`items = Array(items.prefix(500))`) to cap memory footprint without complex eviction data structures.
* **Optimistic Local Mutations & Rollback:**
  * When `e` (archive) is pressed on an email thread, the item is removed immediately from the visible list and an asynchronous task calls `GmailService.archiveThread(id:)` via `users.threads.modify(threadId: ..., removeLabelIds: ["INBOX"])`.
  * If the network call fails after exponential backoff, the item is restored to the store and an unobtrusive notification bar appears.
  * For GitHub notifications, `e` marks the thread as read (`PATCH /notifications/threads/{id}`) without touching the public issue or PR state.
  * When `#` or `Delete` (trash) is pressed:
    * Gmail: Calls `GmailService.trashThread(id:)` via `users.threads.trash(id: item.id)`.
    * GitHub: Calls `GitHubService.unsubscribeNotification(threadId: item.id)` via `DELETE /notifications/threads/{id}/subscription` and marks read locally.
* **Snapshot Persistence:** On `NSApplication.willTerminateNotification`, performs a synchronous atomic file write (`Data.write(to:options: .atomic)`) with `.completeFileProtection` saving the in-memory items to `~/Library/Application Support/DevTriage/snapshot.json`. On cold start, the snapshot renders immediately before network calls begin.

#### D. Detail View & HTML Email Isolation (`DetailPaneView`)
* **Email Rendering:**
  * Uses a single, recycled `WKWebView` instance inside the detail pane to eliminate web view allocation thrashing.
  * Configures `WKWebpagePreferences.allowsContentJavaScript = false` to eliminate XSS risks and script execution latency.
  * Injects a declarative Content Security Policy `<meta>` tag:
    ```html
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src local:">
    ```
    This deterministically blocks all external tracking pixels, remote stylesheets, and CSS `@import` beacons by default without fragile regex string parsing.
  * When the user clicks "Load External Images", re-renders the web view with permissive image policy (`img-src https: data:`).
  * Implements `WKNavigationDelegate.decidePolicyFor` to redirect all hyperlink clicks to `NSWorkspace.shared.open(url)` in the user's default browser.
* **GitHub Rendering:** Pure native SwiftUI text and markdown rendering utilizing `LocalizedStringKey` / `AttributedString`. Fetches full issue body and comments on demand via `GitHubService.fetchIssueDetails(repo:number:)`.

#### E. Local Coding Agent Dispatch (`AgentDispatchService`)
* **Context Assembly:** When triggered (`Cmd+Shift+A` or button click):
  * Retrieves repository name, issue number, title, body, and comments timeline.
  * Resolves local repository path via `PreferencesStore` (e.g., `~/Projects/repo-name`).
* **Clipboard Context Dispatch Execution:**
  1. Formats structured markdown prompt:
     ```markdown
     # Task: Address GitHub Issue #{number} in {repo}
     Title: {title}
     Path: {local_repo_path}

     ## Description
     {body}

     ## Latest Comments
     {comments}
     ```
  2. Writes the formatted text to `NSPasteboard.general`.
  3. Triggers a 1.5-second transient floating toast ("Copied issue context to clipboard").
  4. Activates the user's configured terminal or IDE (Terminal, iTerm2, Ghostty, Alacritty, VS Code) via `NSWorkspace.shared.openApplication(at:configuration:)`.
* **App Sandbox Invariant:** Avoids AppleScript command injection or scripting-addition entitlements. The user simply pastes (`Cmd+V`) into their running CLI agent session (`claude`, `opencode`, `antigravity`).
* **Side-by-Side Reference:** The desktop app keeps the issue view pinned in the detail pane so that when the agent prompts the user in the terminal, the reference context is directly visible.

---

### 3. Data Schema and Domain Model

```swift
import Foundation

enum TriageSource: String, Codable, Sendable, Hashable {
    case gmail
    case gitHub
}

enum ReviewStatus: String, Codable, Sendable, Hashable {
    case pending
    case approved
    case changesRequested
    case none
}

enum CheckSuiteStatus: String, Codable, Sendable, Hashable {
    case queued
    case inProgress
    case completedSuccess
    case completedFailure
    case neutral
}

enum TriageKind: Codable, Sendable, Hashable {
    case email(threadId: String, snippet: String, hasHtml: Bool)
    case gitHubIssue(number: Int, repo: String, state: String, isAssignedToMe: Bool)
    case gitHubPullRequest(number: Int, repo: String, isDraft: Bool, reviewStatus: ReviewStatus, ciStatus: CheckSuiteStatus)
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

struct GitHubIssueDetail: Codable, Sendable, Hashable {
    let repo: String
    let number: Int
    let title: String
    let body: String
    let author: String
    let createdAt: Date
    let comments: [GitHubComment]
}

struct GitHubComment: Codable, Sendable, Hashable {
    let id: Int
    let author: String
    let body: String
    let createdAt: Date
}

struct AgentDispatchPayload: Sendable {
    let issueNumber: Int
    let repository: String
    let title: String
    let body: String
    let comments: [GitHubComment]
    let localRepoPath: URL?
    
    var formattedPrompt: String {
        let commentsText = comments.isEmpty 
            ? "No comments." 
            : comments.map { "### @\($0.author) on \($0.createdAt):\n\($0.body)" }.joined(separator: "\n\n---\n\n")
            
        let pathLine = localRepoPath != nil ? "Local Path: \(localRepoPath!.path)\n" : ""
        
        return """
        # Task: Address GitHub Issue #\(issueNumber) in \(repository)
        Title: \(title)
        \(pathLine)
        ## Description
        \(body)
        
        ## Comments
        \(commentsText)
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

### Alternative E: Embedded Terminal Emulator or AppleScript Command Injection for AI Agents

* **Pros:** Automates direct command execution inside a terminal window without user paste.
* **Cons:** Embedding a terminal emulator requires implementing a full pseudo-terminal (PTY) runner and parsing ANSI escapes, requiring disabling macOS App Sandbox. Using AppleScript to inject dynamic shell text into external terminals requires temporary exception entitlements (`com.apple.security.temporary-exception.apple-events`), introduces security vulnerabilities, and breaks across different terminal emulators (Ghostty, iTerm2, VS Code terminal).
* **Reason for Rejection:** The Clipboard Context Dispatch pattern (`Cmd+Shift+A` copies markdown prompt to `NSPasteboard`, displays toast, activates user's terminal/IDE) preserves strict App Sandbox isolation, works across all terminal emulators without entitlements, and avoids fragile UI scripting.

### Alternative F: Merged Single Stream (Gmail + GitHub Combined)

* **Pros:** One unified inbox feed for all asynchronous notifications.
* **Cons:** Causes cognitive confusion by interweaving personal correspondence with automated CI alerts and code review pings. Requires complex, brittle heuristics to deduplicate GitHub notification emails from GitHub API events.
* **Reason for Rejection:** Dedicated sidebar workspaces provide clean mental separation of concerns.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### 1. Performance & Resource Footprint
* **Memory Budget:** Idle resident set size (RSS) must remain strictly under 50 MB. When `WKWebView` renders complex HTML emails, memory usage must not exceed 90 MB and must return to base levels upon switching to GitHub markdown views.
* **Latency:** Keyboard navigation (`j`/`k`) and optimistic triage state updates (`e`, `s`, `#`) must complete within 16 milliseconds (60 fps frame budget). Cold start from snapshot to interactive UI must complete under 100 milliseconds.
* **Battery & Power:** Zero background CPU usage during macOS App Nap or system sleep. Polling strictly suspended during sleep states.

### 2. Security & Privacy
* **App Sandbox:** Configured with `com.apple.security.app-sandbox` and `com.apple.security.network.client`. Zero temporary exception entitlements.
* **Keychain Storage:** All Google OAuth tokens and GitHub Personal Access Tokens stored in macOS Keychain with access control set to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
* **WebKit Isolation:** `WKWebView` runs with `allowsContentJavaScript = false`. Injects declarative CSP `<meta>` tag blocking all external tracking pixels and remote stylesheets by default. Outbound link clicks routed exclusively to `NSWorkspace.shared.open`.
* **Snapshot Storage:** Synchronous atomic file writes with `.completeFileProtection`.

### 3. Reliability & Rollout
* **Network Partition Tolerance:** Network disconnection pauses polling gracefully without user-facing alert modals. Reconnection automatically triggers an immediate sync refresh.
* **Stale History Invalidation:** Handles Gmail HTTP 404 `INVALID_HISTORY_ID` by automatically falling back to full reconciliation via `users.threads.list(q: "label:INBOX")` without corrupting in-memory state.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Target Files to Create/Modify

#### 1. `Package.swift` (Create)
* **Type / Scope:** Swift Package Manager Build Manifest
* **Specification:** Defines the `DevTriage` executable target with macOS 14+ deployment target and Swift 6 language mode. Explicitly sets `dependencies: []`. Uses standard Apple frameworks (`Foundation`, `SwiftUI`, `AuthenticationServices`, `WebKit`, `Security`, `Network`).

#### 2. `Sources/DevTriage/App/DevTriageApp.swift` (Create)
* **Type / Scope:** Application Entrypoint & Lifecycle
* **Specification:** `@main struct DevTriageApp: App`. Configures main `WindowGroup` (1100x700) and `Settings` scene. Instantiates `PreferencesStore`, `AuthService`, `GmailService`, `GitHubService`, `TriageStore`, and `SyncCoordinator` at the composition root. Coordinates synchronous snapshot persistence on app termination.

#### 3. `Sources/DevTriage/Models/TriageItem.swift` (Create)
* **Type / Scope:** Core Domain Entities
* **Specification:** Defines `TriageSource` (`gmail`, `gitHub`), `ReviewStatus`, `CheckSuiteStatus`, `TriageKind` (distinguishing emails, issues, PRs, and notifications), `TriageItem`, `GitHubIssueDetail`, and `GitHubComment`. Defines `AgentDispatchPayload` with formatted markdown compilation logic for CLI agents.

#### 4. `Sources/DevTriage/State/TriageStore.swift` (Create)
* **Type / Scope:** Observable Presentation State
* **Specification:** `@Observable @MainActor final class TriageStore`. Maintains `gmailItems` and `gitHubItems` arrays, active stream filter, and selected item ID. Implements optimistic actions:
  - `archive(item:)`: Removes item locally and calls `GmailService.archiveThread` or `GitHubService.dismissNotification`.
  - `star(item:)`: Toggles starred state locally and remotely.
  - `trash(item:)`: Calls `GmailService.trashThread` or `GitHubService.unsubscribeNotification`.
  - `markUnread(item:)`: Toggles unread state.
  - Enforces 500-item bound via `items = Array(items.prefix(500))`. Handles network failure rollback with user-facing undo toast. Owns synchronous atomic snapshot saving and launch loading.

#### 5. `Sources/DevTriage/Services/AuthService.swift` (Create)
* **Type / Scope:** OAuth 2.0 PKCE & Keychain Wrapper
* **Specification:** Implements `ASWebAuthenticationSession` with reverse-DNS scheme `com.googleusercontent.apps.<client-id>:/oauth2redirect` for Gmail. Provides strongly typed CRUD operations for macOS Keychain using `Security.framework` (`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`) with device-unlocked protection. Stores and validates GitHub Personal Access Token.

#### 6. `Sources/DevTriage/Services/GmailService.swift` (Create)
* **Type / Scope:** Google Gmail REST API Engine
* **Specification:** Client conforming to `Sendable`. Implements:
  - `getProfile()`: Retrieves user email and baseline `historyId`.
  - `fetchInboxThreads(pageToken:)`: Initial bootstrap and reconciliation via `users.threads.list(q: "label:INBOX")`.
  - `fetchHistory(since:)`: Incremental polling via `users.history.list`. Detects HTTP 404 `INVALID_HISTORY_ID` and triggers full inbox reconciliation.
  - `fetchThreadDetails(id:)`: Fetches full thread messages and MIME bodies.
  - `archiveThread(id:)`: Removes `INBOX` label via `users.threads.modify`.
  - `trashThread(id:)`: Moves thread to trash via `users.threads.trash`.

#### 7. `Sources/DevTriage/Services/GitHubService.swift` (Create)
* **Type / Scope:** GitHub REST API v3 Engine
* **Specification:** Client conforming to `Sendable`. Implements:
  - `fetchNotifications(lastETag:)`: Polls `/notifications` with `If-None-Match`. Returns `.notModified` on HTTP 304, consuming zero quota.
  - `fetchCheckRuns(owner:repo:ref:)`: REST v3 check runs for CI alerts.
  - `fetchIssueDetails(repo:number:)`: On-demand retrieval of issue body and comment timeline.
  - `dismissNotification(threadId:)`: Executes `PATCH /notifications/threads/{threadId}`.
  - `unsubscribeNotification(threadId:)`: Executes `DELETE /notifications/threads/{threadId}/subscription`.

#### 8. `Sources/DevTriage/Services/SyncCoordinator.swift` (Create)
* **Type / Scope:** Concurrency & Background Polling Actor
* **Specification:** Swift `actor` orchestrating polling cycles. Runs continuous 45s timer loop without jitter. Subscribes to `NWPathMonitor` for connection status and `NSWorkspace.willSleepNotification` / `didWakeNotification` to suspend during sleep and perform instant wake updates. Dispatches fresh items to `TriageStore` on `@MainActor`.

#### 9. `Sources/DevTriage/Services/AgentDispatchService.swift` (Create)
* **Type / Scope:** CLI Coding Agent Context Dispatcher
* **Specification:** Assembles markdown prompt, writes to `NSPasteboard.general`, triggers a 1.5s transient floating toast, and activates the user's configured terminal emulator or IDE via `NSWorkspace.shared.openApplication`.

#### 10. `Sources/DevTriage/State/PreferencesStore.swift` (Create)
* **Type / Scope:** User Preferences Management
* **Specification:** `@Observable final class PreferencesStore`. Manages persisted settings via `UserDefaults`: Google Client ID, GitHub PAT, default local projects directory (`~/Projects`), and preferred terminal application (`Terminal`, `iTerm2`, `Ghostty`, `VSCode`).

#### 11. `Sources/DevTriage/Views/MainSplitView.swift` (Create)
* **Type / Scope:** 3-Column Root View Layout
* **Specification:** `NavigationSplitView` hosting `SidebarView`, `TriageStreamView`, and `DetailPaneView`. Installs `@FocusState private var isSearchFocused: Bool` to guard single-key hotkeys (`j`/`k`, `e`, `s`, `u`, `#`, `Cmd+Shift+A`, `Cmd+O`), ensuring shortcuts do not intercept text fields.

#### 12. `Sources/DevTriage/Views/SidebarView.swift` (Create)
* **Type / Scope:** Navigation Sidebar
* **Specification:** Workspace selection buttons for **Gmail** and **GitHub** with unread count pills. Smart filter sections for GitHub: `CI Alerts` (failures), `Mentions`, and `Review Requests`.

#### 13. `Sources/DevTriage/Views/TriageStreamView.swift` (Create)
* **Type / Scope:** Virtualized Item List
* **Specification:** Dense list view displaying `TriageItem` rows with unread indicators, relative dates, author avatars, title, two-line snippet, and status badges.

#### 14. `Sources/DevTriage/Views/DetailPaneView.swift` (Create)
* **Type / Scope:** Detail Inspector Pane
* **Specification:** Displays `RecycledWKWebView` for Gmail messages or native SwiftUI markdown view for GitHub issues. On GitHub issues, fetches full body and comments timeline on-demand via `GitHubService.fetchIssueDetails`. Displays action bar with "Dispatch to Agent" button (`Cmd+Shift+A`).

#### 15. `Sources/DevTriage/Views/Components/RecycledWKWebView.swift` (Create)
* **Type / Scope:** Sandboxed AppKit WebKit Wrapper
* **Specification:** `NSViewRepresentable` managing a single reusable `WKWebView`. Disables JavaScript (`allowsContentJavaScript = false`), injects declarative CSP `<meta>` tag blocking remote trackers, and intercepts link clicks via `decidePolicyFor` to open in external browser.

#### 16. `Sources/DevTriage/Views/SettingsView.swift` (Create)
* **Type / Scope:** Preferences & Account Configuration View
* **Specification:** SwiftUI `Settings` scene with tabs for Accounts (Google OAuth Client ID sign-in, GitHub Personal Access Token) and Agent Dispatch (local projects folder path picker, preferred terminal selector).

#### 17. `Sources/DevTriage/Views/OnboardingView.swift` (Create)
* **Type / Scope:** First-Run Setup Card
* **Specification:** Empty-state view presented when credentials are missing, offering 1-click Google sign-in and a guide for generating a GitHub PAT.

#### 18. `DevTriage.entitlements` (Create)
* **Type / Scope:** macOS App Sandbox Configuration
* **Specification:** Declares `com.apple.security.app-sandbox = true` and `com.apple.security.network.client = true`. Zero temporary exception entitlements.

#### 19. `Info.plist` (Create)
* **Type / Scope:** Bundle Configuration
* **Specification:** Declares `CFBundleIdentifier`, `CFBundleName`, `CFBundleVersion`, and `CFBundleURLTypes` registering the custom reverse-DNS redirect URI scheme `com.googleusercontent.apps.<client-id>`.

#### 20. `scripts/package-app.sh` (Create)
* **Type / Scope:** macOS Application Packaging Script
* **Specification:** Automates building the release binary via `swift build -c release`, creating the `DevTriage.app` directory hierarchy (`Contents/MacOS`, `Contents/Resources`), copying the binary and `Info.plist`, and code-signing with `DevTriage.entitlements`.

#### 21. `Tests/DevTriageTests/SyncCoordinatorTests.swift` (Create)
* **Type / Scope:** Synchronization Concurrency Unit Tests
* **Specification:** Validates incremental polling, ETag caching (304), network interruption recovery, and HTTP 404 `INVALID_HISTORY_ID` recovery logic using mock `URLProtocol`.

#### 22. `Tests/DevTriageTests/TriageStoreTests.swift` (Create)
* **Type / Scope:** State & Optimistic Mutation Tests
* **Specification:** Validates 500-item array prefix capping, optimistic archive/trash deletion with rollback on simulated network failure, and synchronous atomic snapshot serialization.

#### 23. `Tests/DevTriageTests/AgentDispatchTests.swift` (Create)
* **Type / Scope:** Agent Context Assembly Tests
* **Specification:** Validates markdown prompt generation from issues and PR comments, verifying sanitization and file path resolution.

---

### Verification Plan

* **Compilation/Build:**
  * Clean build via Swift Package Manager: `swift build -c release`
  * Verify zero compiler warnings under Swift 6 language mode (`-swift-version 6`).
* **App Bundle Packaging & Code Signing:**
  * Package the application: `./scripts/package-app.sh`
  * Verify signature and entitlements: `codesign --verify --deep --strict DevTriage.app`
  * Inspect entitlements: `codesign -d --entitlements :- DevTriage.app`
* **Unit Tests:**
  * Execute test suite: `swift test`
  * Verify 100% pass rate across state machine, 500-item array capping, ETag 304 parsing, and Keychain mocking.
* **Static Analysis & Linting:**
  * Run `swift format lint --strict` (or `swiftlint` if present).
* **Resource Benchmarking:**
  * Validate memory footprint in macOS Activity Monitor: verify idle RSS < 50 MB, detail pane WebKit peak < 90 MB.
  * Validate 0.0% CPU usage while window is closed or system is asleep.
* **Manual Critical User Journey Verification:**
  * Validate OAuth login flow with personal Google Cloud Client ID via reverse-DNS custom scheme.
  * Validate `j`/`k` list traversal, `e` keyboard archiving, and `#` trash against live Gmail inbox.
  * Validate `Cmd+Shift+A` context dispatch copying markdown prompt to clipboard and activating external terminal.

--------------------------------------------------------------------------------

*Drafted with EGM*
