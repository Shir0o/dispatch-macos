# Architectural Evaluation: Gmail API vs. IMAP & macOS Tech Stacks

* **Date:** 2026-11-03
* **Context:** Evaluation for a lightweight, personal-first, open-source macOS Gmail client focused on triage, grouping, and clean aesthetics.

---

## 1. Protocol Comparison: Gmail REST API vs. IMAP with Gmail Extensions

### Gmail REST API

The Gmail REST API operates over HTTP/JSON and models email according to Google's internal data store: threads, messages, and labels (which act as tags rather than physical folders).

#### Advantages
* **Native Gmail Semantics:** Threads (`threadId`), labels (`labelIds`), and history IDs (`historyId`) are first-class primitives. Archiving an email is a single API call removing the `INBOX` label without moving data across folders.
* **Server-Side Search:** Supports identical search operators as the Gmail web app (`from:`, `is:unread`, `has:attachment`, `label:`) without downloading indices locally.
* **Efficient Partial Fetching:** Allows fetching metadata only (headers, snippet, thread state) without downloading message bodies or attachments until explicitly opened.
* **Incremental Synchronization:** The `users.history.list` endpoint returns an exact changelog since a known `historyId` (added labels, removed labels, deleted messages), eliminating state reconciliation diffs.

#### Disadvantages & Critical Constraints
* **No Direct Push to Desktop Clients:** The Gmail API `watch` mechanism sends events strictly to a **Google Cloud Pub/Sub** topic. To receive instant push notifications, a client must either:
  1. Maintain an active gRPC/HTTP subscription to Google Cloud Pub/Sub (requiring Google Cloud project setup, service account credentials, and potential quota/billing considerations).
  2. Fall back to periodic polling using `users.history.list` (e.g., every 30–60 seconds).
* **OAuth Friction:** Scopes like `gmail.modify` are restricted. For personal use, running a local HTTP server on `127.0.0.1` to catch the OAuth redirect works. For other users in an open-source distribution, each user must set up their own Google Cloud Console project or use an external proxy.

---

### IMAP with Gmail Extensions (`X-GM-EXT-1`)

Gmail provides an IMAP interface that includes custom extensions (`X-GM-THRID`, `X-GM-MSGID`, `X-GM-LABELS`, and `X-GM-RAW` for search).

#### Advantages
* **True Real-Time Push via IMAP IDLE:** The client keeps an open TCP connection to `imap.gmail.com:993` and issues `IDLE`. Google notifies the client of incoming mail in real time without third-party cloud infrastructure (Pub/Sub) or polling loops.
* **Standard Protocol:** Well-tested libraries exist in almost every language.

#### Disadvantages & Critical Constraints
* **Folder Impedance Mismatch:** IMAP models mail as a hierarchy of folders. In Gmail, an email with three labels appears in three separate IMAP folders. Archiving requires copying to `[Gmail]/All Mail` and expunging from `INBOX`, leading to sync duplication and quota issues.
* **Fragile Connection Management:** IMAP connections over Wi-Fi drop frequently on laptop sleep/wake. Reconnecting, re-authenticating, and re-establishing `IDLE` state across network changes requires extensive connection-recovery code.
* **Authentication Obstacles:** Requires either SASL XOAUTH2 (which still requires Google OAuth) or an App Password (which requires the user to enable 2FA and create an application-specific credential).

---

## 2. Tech Stack Evaluation for macOS

| Criteria | Swift + SwiftUI (Native) | Rust + Tauri v2 (WebKit UI) | Go / Python / Electron |
| :--- | :--- | :--- | :--- |
| **UI Aesthetics & Integration** | Native macOS controls, animations, typography, toolbar, and dark mode out of the box. | Web-rendered (HTML/CSS) inside macOS WebKit webview. Custom CSS required to emulate macOS design. | Electron: heavy, non-native feel. Python: crude GUI options. Go/Wails: webview-based. |
| **Memory Footprint** | ~30 MB idle base; rises to ~70–90 MB when `WKWebView` renders an email body. | ~50–80 MB idle (WebKit host process). | ~200–500+ MB idle (Chromium runtime). |
| **Binary Size** | ~10–25 MB standalone. | ~15–30 MB. | ~120–250 MB. |
| **HTML Email Rendering** | Embeds `WKWebView` for message bodies; native SwiftUI for lists and sidebar. | HTML rendering is native to the webview frame, but security sandboxing between app UI and untrusted email HTML is complex. | Standard DOM rendering, high security vulnerability surface for XSS in email bodies. |
| **Build & Distribution** | Requires Xcode on macOS. Zero external runtime dependencies; no Docker. | Requires Rust + Cargo + Node/Web tooling. | Requires Node runtime, Docker (if using self-hosted bridges), or Python env. |

### Recommendation
**Swift + SwiftUI (AppKit bridge where needed):**
- Delivers authentic macOS aesthetics without fighting CSS framework approximations.
- Runs without external runtimes, containers, or background daemon processes.
- Memory remains minimal: SwiftUI renders the fast list and split view, while a sandboxed, reusable `WKWebView` instance renders the selected HTML message body.

---

## 3. Scope Analysis: Triage, Grouping, and Push

### 1. Triage Workflow (Check & Archive)
- The core interaction model maps directly to keyboard shortcuts: `j`/`k` (navigate), `e` or `y` (archive = remove `INBOX` label), `s` (star/flag), `d` (trash).
- Zero local SQLite database required for an online-first client. An in-memory cache of the current view's messages and thread snippets avoids disk sync overhead and state divergence.

### 2. Grouping (e.g., CI/CD Failures, GitHub Notifications)
- **Mechanism:** Rule-based virtual bucketing based on headers and labels.
  - GitHub sends specific headers: `List-ID`, `X-GitHub-Reason` (e.g., `ci_activity`, `author`, `mention`).
  - The client can group threads into client-side buckets (e.g., "CI Failures", "Newsletters", "Direct") dynamically without altering Gmail labels on the server.
- **Rule Engine:** Plain configuration (YAML/JSON) matching headers, sender domain, or subject regex.

### 3. Push and Update Strategy
- Because the target is a lightweight local desktop app without external servers, **periodic polling via `users.history.list`** (every 30 to 60 seconds while active, backed off when window is minimized) is significantly simpler and more resilient than hosting a Google Cloud Pub/Sub receiver.
- An optional local IMAP IDLE connection can run in the background strictly as a "wake-up bell" to trigger a Gmail REST API fetch if true real-time arrival (<2 seconds) is required.

---

## 4. Trade-off Analysis: Skipping Docker vs. Self-Hosted Container Architecture

Open-source email utilities often lean on Docker to run headless background sync engines (e.g., Nylas Sync Engine, Mailspring's C++ daemon, or self-hosted webhook proxies).

### Skipping Docker (Native Standalone Client)
* **Advantages:**
  * **Zero System Overhead:** Docker Desktop on macOS runs a full Linux hypervisor VM (QEMU/Hypervisor.framework), routinely taking 2 to 4 GB of RAM and causing sustained battery drain on laptops. A native app uses 30–80 MB.
  * **Direct Onboarding:** Single binary drag-and-drop (`.app` / `.dmg`). No terminal commands, container image pulls, volume configuration, port bindings, or container daemon health checks.
  * **Native Power Management:** Participates in macOS App Nap and system sleep states.
* **Disadvantages:**
  * **Lifecycle Boundary:** The client only syncs or processes updates while running. It cannot run headless 24/7 background worker jobs unless packaged as a macOS LaunchAgent / background daemon.
  * **Embedded Service Burden:** Any capability like full-text search or local caching cannot offload to containerized tools (like Redis, Elasticsearch, or Meilisearch) and must run in-process via embedded libraries (e.g., SQLite with FTS5).

---

## 5. Scope Expansion Analysis: Task Management & GitHub Issues Integration

The user raised adding a task layer (similar to Macro) where GitHub issues appear alongside or within the email triage workflow.

### Complexity & Scope Risk Assessment
1. **API Expansion:** Integrating GitHub issues requires adding a second authentication mechanism (GitHub OAuth or Personal Access Token), tracking separate API rate limits (5,000 requests/hour), and handling two distinct data stores.
2. **Data Model Divergence:**
   * Gmail data model: Message ID, Thread ID, Labels, Sender, Snippet, Date. Actions: Read, Star, Archive, Trash.
   * GitHub Issues data model: Repo, Issue Number, State (Open/Closed), Assignee, Milestone, Labels, Comments. Actions: Close, Reopen, Assign, Comment, Merge.
   * Merging these into a unified triage feed requires either an artificial abstraction layer or parsing GitHub notification emails directly.
3. **Execution Options:**
   * **Approach A: Pure Email-Driven Grouping (Zero GitHub API).** Treat incoming GitHub notifications as specialized email threads. Use email headers (`List-ID: <repo.owner.github.com>`, `X-GitHub-Reason`) to cluster issues. Actions only mutate email state (e.g., mark as done = archive email).
   * **Approach B: Native Dual-Client (Gmail + GitHub REST API).** The client connects directly to both Gmail and GitHub. It displays an inbox for emails and a list for assigned GitHub issues. Allows closing issues from the desktop client.
   * **Critique:** Approach B breaks the "without much bloat, simple and works" premise by turning an email client into an issue tracker. Approach A preserves a single data engine while achieving 80% of the triage convenience.

