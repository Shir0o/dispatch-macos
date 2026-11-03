# Native macOS Developer Triage Client (Gmail & GitHub)

* **Author:** Antigravity & User
* **Date:** 2026-11-03

## Overview

A lightweight, native macOS desktop application built in Swift and SwiftUI dedicated to rapid triage of personal Gmail messages and GitHub notifications (issues and pull requests). The application replaces heavy web-wrapped or containerized setups with a clean, low-footprint desktop client. It relies on the Gmail REST API for label-based archiving and GitHub REST/GraphQL APIs for issue state updates, operating an online-first model backed by a local JSON cold-start cache.

## Analysis

The multi-lens Goldfish review surfaced several technical trade-offs and operational risks across architecture, systems, UX, and data modeling:

### 1. Distinct Streams vs. Cross-Stream Deduplication
The user established that Gmail and GitHub must remain **distinct views/tabs** rather than being mashed into a single hybrid feed.
* **Finding:** Separating the streams avoids brittle cross-service heuristics and preserves clean mental models.
* **Mechanism:** The sidebar features two primary workspaces:
  1. **Gmail:** Focuses strictly on personal email threads, folders/labels, and unread triage.
  2. **GitHub:** Focuses on assigned issues, open PRs, mentions, and CI failure notifications.

### 2. Triage Invariants & Destructive Action Boundaries
* **Finding:** Fast keyboard triage (`e`) must never mutate public shared state on GitHub.
* **Mechanism:**
  * For Gmail: `e` removes the `INBOX` label (personal archive).
  * For GitHub: `e` marks the notification thread as read/done via GitHub API (`PATCH /notifications/threads/{id}`). It does **not** close or modify the public issue or pull request.
  * Issue state changes (e.g., closing an issue) remain strictly manual actions via explicit buttons or a dedicated hotkey (`Shift+C`) with a confirmation dialog.

### 3. Local Coding Agent Integration (Claude, OpenCode, Antigravity)
The user raised connecting local coding agents (e.g., Claude Code, OpenCode, Antigravity) to bridge the context gap when an agent asks questions about an issue.

#### The Technical Reality of Local Agent Subscriptions
* Web subscriptions (Claude Pro/Max, ChatGPT Plus) cannot be accessed directly via third-party desktop API calls.
* Local CLI tools (Claude Code CLI, OpenCode, Antigravity CLI) authenticate locally via OAuth tokens stored in the user's home directory (`~/.claude`, `~/.config/opencode`).
* To utilize existing CLI subscriptions without paying per-token API fees, the desktop app must execute the existing local CLI binary rather than calling remote cloud LLM APIs.

#### Architectural Obstacles & Constraints
1. **App Sandbox Conflict:** A sandboxed macOS app (`com.apple.security.app-sandbox`) cannot spawn arbitrary CLI processes from `/usr/local/bin` or `~/.local/bin`. To execute local agents directly, the app must either:
   * Disable App Sandbox (acceptable for personal open-source builds distributed via GitHub releases or Homebrew Cask, but precludes Mac App Store distribution).
   * Delegate execution via external terminal automation (e.g., opening a pre-populated terminal window via AppleScript / `NSWorkspace`).
2. **Terminal Emulation Complexity:** Embedding an interactive CLI agent inside the app requires handling pseudo-terminal (PTY) communication, ANSI escape codes, terminal resizing, and interactive prompt piping. This risks transforming a lightweight triage app into a complex terminal emulator.
3. **The Context-Bridging Solution:**
   * Instead of building an entire terminal emulator inside the client, provide a **"Dispatch to Agent"** action.
   * Clicking "Dispatch" compiles the full issue title, body, comments, labels, and local repo file path into a structured payload.
   * The app opens the user's preferred terminal (or Antigravity/Claude workspace) pre-loaded with the prompt, while keeping the full issue detail pane visible side-by-side on screen for immediate reference during agent clarifying questions.

### 4. Gmail Synchronization Invariants & `historyId` Invalidation
* **Finding:** Incremental polling against `users.history.list` relies on a monotonically increasing `historyId`. If an account remains inactive or offline for an extended duration (~7 days), Google invalidates the `historyId`, returning an HTTP `404` or `INVALID_HISTORY_ID` error.
* **Mechanism:** The `SyncCoordinator` actor must detect this failure status and trigger a full label reconciliation rather than failing silently or hanging.

### 5. Rate Limit Conservation & Battery Preservation
* **Finding:** Polling two external services every 30–60 seconds risks draining API limits and causing CPU wakeups during laptop sleep.
* **Mechanism:**
  * For GitHub, all polling requests must supply `If-None-Match: <ETag>`. HTTP `304 Not Modified` responses consume zero GitHub rate quota.
  * The synchronization engine must monitor macOS workspace notifications (`NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`). Polling pauses during system sleep and runs an immediate refresh upon waking.

### 6. WKWebView Isolation and Memory Management
* **Finding:** Spawning a new `WKWebView` instance per email list item leads to excessive memory allocation and potential leaks in WebKit helper processes. Untrusted HTML emails also present cross-site scripting and tracking risks.
* **Mechanism:**
  * Allocate a single reusable `WKWebView` instance inside the detail inspection pane, reusing it across selection changes via `loadHTMLString`.
  * Disable JavaScript execution (`WKWebpagePreferences.allowsContentJavaScript = false`).
  * Block remote tracking pixels and external image assets by default, offering a per-email toggle to load remote media.
  * Intercept link navigation to route outbound clicks to the system default browser.

---

## Goals vs. Non-Goals

### In-Scope Goals
* **Native macOS Shell:** Pure Swift 6 and SwiftUI implementation utilizing `NavigationSplitView` with San Francisco typography and native system styling.
* **Distinct Workspaces:** Dedicated sidebar views for **Gmail** (inbox triage, archiving) and **GitHub** (assigned issues, PR review requests, CI failures).
* **Safe Keyboard Triage:** Vim/Superhuman-style shortcuts (`j`/`k` navigate, `e`/`y` archive/dismiss notification, `s` star, `#`/`Delete` trash, `u` unread, `Cmd+O` open in browser). Local triage (`e`) never mutates remote issue states.
* **Local Coding Agent Dispatch:** 1-click or hotkey action (`Cmd+Shift+A`) that bundles the full GitHub issue context (title, description, repro steps, comments, local repo path) into a structured prompt, automatically dispatching to the user's preferred local agent CLI (Claude Code, OpenCode, Antigravity) without manual copy-pasting.
* **Persistent Issue Reference:** Issue detail pane remains pinned and readable side-by-side so the user can easily answer agent clarifying questions without opening browser tabs.
* **Rule-Based Notification Clustering:** Client-side filters that isolate and group specific noise (e.g., CI test failures, direct mentions, automated bot alerts from Dependabot/Renovate).
* **Local In-Memory Architecture:** Sub-50ms interaction response using an in-memory observable store, augmented with an ephemeral JSON cache snapshot written on app quit for instant cold starts.
* **Secure Keychain Storage:** OAuth tokens for Gmail and GitHub stored strictly in macOS Keychain via `Security.framework`.

### Out-of-Scope Non-Goals
* **Embedded Terminal Emulator:** The app will not bundle an internal PTY/terminal runner or reimplement terminal interfaces. Agent execution happens via the user's configured terminal or IDE.
* **Email Composition & Rich Text Editing:** No email drafting, WYSIWYG editor, or reply workflows in v1.
* **Full Offline Relational Database:** No local multi-gigabyte SQLite cache of historical email archives or attachments.
* **Containerized or Daemon Architecture:** No Docker containers, Redis queues, or background daemon processes.
* **Universal Multi-Provider Support:** No generic IMAP/POP3, Outlook, or Exchange support; limited strictly to Gmail REST API and GitHub.
* **Full GitHub Project Management:** No board views, milestone management, or repo administration tools.

---

## Alternatives Weighed

| Alternative | Considered For | Reason Rejected |
| :--- | :--- | :--- |
| **Merged Single Feed (Gmail + GitHub)** | Stream architecture | Mixing two fundamentally different communication channels into a single feed causes cognitive overload and requires fragile heuristics to deduplicate notifications. Distinct views provide clear separation of concerns. |
| **Direct Remote Issue Closure on Archive (`e`)** | Triage interaction | Conflating personal inbox clearance with public issue closure risks accidental repo mutations during fast keyboard triage. Dismissing notifications must remain decoupled from issue state transitions. |
| **Embedded In-App Terminal Emulator for AI Agents** | Coding agent integration | Reimplementing terminal emulation (PTY, ANSI colors, cursor control) adds thousands of lines of brittle code and breaks macOS App Sandbox. Dispatching to the external terminal with structured context solves the problem with zero bloat. |
| **IMAP with Gmail Extensions (`X-GM-EXT-1`)** | Email protocol | IMAP models tags as folders, causing synchronization duplication during archiving (`[Gmail]/All Mail` vs `INBOX`). IMAP IDLE connections also drop unpredictably over Wi-Fi transitions. |
| **Docker-Based Sync Backend (e.g., Nylas/Mailspring)** | Synchronization engine | Consumes 2–4 GB of memory via Linux hypervisor VM on macOS, adds severe setup friction, and drains battery. |
| **Electron / Chromium Runtime** | Cross-platform UI | High memory footprint (>500 MB idle), sluggish startup times, and non-native macOS user experience. |
| **Two-Way Database Sync (SQLite FTS5)** | Storage layer | Unnecessary for a triage-first client. Adds database migration complexity, schema lock issues, and disk sync overhead. In-memory storage with an ephemeral quit snapshot provides faster UI response. |

---

## Key Decisions & Staging for Next Steps

1. **Protocol & Auth:** Authenticate via `ASWebAuthenticationSession` using PKCE. Persist access and refresh tokens directly in the macOS Keychain.
2. **Sync Loop:** Implement an actor-based `SyncCoordinator` polling Gmail `users.history.list` and GitHub `/notifications` every 30–60 seconds, honoring `If-None-Match` ETags and system sleep/wake notifications.
3. **Detail Rendering:** Single recycled `WKWebView` instance in the detail pane with JavaScript disabled and external tracking images blocked.
4. **Stream Isolation & Agent Dispatch:** Gmail and GitHub maintain separate sidebar workspaces. Provide a 1-click/hotkey 'Dispatch to Agent' action on issues that copies or launches the prompt with full issue context to local CLI agents (Claude Code, OpenCode, Antigravity) without embedding a full terminal runner.
5. **Next Step:** Review the synthesized brief with the user and resolve any remaining questions before initiating formal design drafting via `/egm-draft`.
