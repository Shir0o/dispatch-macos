# DevTriage for macOS

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](https://apple.com/macos)
[![Language](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

> A lightweight, open-source native macOS triage client for Gmail and GitHub. Zero Docker containers. Zero Electron runtimes. Sub-50ms interaction latency.

---

## The Vision

Software developers are constantly context-switching between asynchronous personal/work email and GitHub activity (code reviews, assigned issues, and CI failure alerts). Existing options present significant trade-offs:

* **Resource Bloat:** Web-wrapped clients (Electron) and containerized self-hosted sync engines consume 500 MB to 4 GB of RAM, running persistent background Linux VMs that quickly drain laptop batteries.
* **Dated Desktop Clients:** Traditional desktop mail clients either lack Gmail-native label tag semantics (forcing multi-folder duplication via IMAP) or offer zero integration with GitHub issue and PR triage.
* **Fragmented AI Workflows:** When running local AI coding agents (Claude Code, OpenCode, Antigravity) in the terminal, developers lose track of issue reproduction details and context when the agent asks clarifying questions.

**DevTriage** is a native Swift 6 and SwiftUI client engineered specifically for rapid developer triage.

---

## Key Features

* **Authentic Native macOS Performance:** Built with pure SwiftUI (`NavigationSplitView`) and AppKit integration. Sub-50ms response times for keyboard triage and an idle memory footprint under 50 MB.
* **Stream Isolation:** Dedicated workspaces for **Gmail** and **GitHub**, preventing developer noise and CI alerts from polluting personal correspondence.
* **Vim/Superhuman Keyboard Navigation:**
  * `j` / `k`: Next / Previous item
  * `e`: Archive email (removes `INBOX` label) or mark GitHub notification as done
  * `s`: Star / pin item
  * `u`: Mark unread
  * `#` or `Delete`: Trash / dismiss
  * `Cmd+O`: Open thread / issue directly in default browser
* **Non-Destructive Invariant:** Fast triage (`e`) archives personal inbox messages or dismisses notifications. It **never** mutates public GitHub issue states (closing an issue remains an explicit action).
* **Local Coding Agent Dispatch (`Cmd+Shift+A`):**
  * Bundles issue title, reproduction steps, comments, labels, and local repo paths into a structured markdown prompt.
  * Dispatches the prompt to your configured local CLI agent (`claude`, `opencode`, `antigravity`) in your favorite terminal (Terminal, iTerm2, Ghostty).
  * Pins the issue details side-by-side in DevTriage so you can answer agent clarifying questions without opening browser tabs.
* **WebKit Isolation & Security:**
  * Single recycled `WKWebView` instance in the detail pane.
  * JavaScript execution strictly disabled (`allowsContentJavaScript = false`).
  * Remote tracking pixels blocked by default with an on-demand image toggle.
  * Dark mode CSS automatically injected.
* **Zero Container / Zero Daemon Overhead:** Runs completely standalone. Cold start loads instantly from an ephemeral quit snapshot (`snapshot.json`). Tokens stored securely in the macOS Keychain.

---

## Technical Architecture

DevTriage is structured around Swift 6 structured concurrency and isolated background actors:

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

For complete technical specifications, data schemas, and design trade-offs, see the [Technical Design Document](docs/designs/dev_triage_macos.md).

---

## Project Structure

```
dev-triage-macos/
├── Package.swift                    # SPM manifest (zero external dependencies)
├── Sources/
│   └── DevTriage/
│       ├── App/                     # Application lifecycle & window management
│       ├── Models/                  # Domain entities (TriageItem, TriageKind)
│       ├── State/                   # Bounded in-memory observable store
│       ├── Services/                # Gmail, GitHub, Auth, SyncCoordinator, AgentDispatch
│       └── Views/                   # NavigationSplitView, Stream, Detail & WKWebView
├── Tests/
│   └── DevTriageTests/              # Concurrency, state machine, and parsing unit tests
├── docs/
│   └── designs/
│       ├── dev_triage_macos.md      # Formal Technical Design RFC
│       └── SITEMAP.md               # Designs index
├── LICENSE                          # Apache License 2.0
├── CONTRIBUTING.md                  # Contribution guidelines
└── README.md
```

---

## Prerequisites & Building

* **Operating System:** macOS 14.0 (Sonoma) or newer.
* **Toolchain:** Xcode 15+ or Swift 6.0 toolchain.
* **Google Cloud Project (for Personal OAuth):** A standard Google Cloud Console Desktop OAuth Client ID (for personal Gmail REST API access).
* **GitHub Personal Access Token or OAuth:** Fine-grained or classic token with `notifications` and `repo` read scopes.

### Build and Run

```bash
# Clone the repository
git clone https://github.com/Shir0o/dev-triage-macos.git
cd dev-triage-macos

# Build release binary
swift build -c release

# Run test suite
swift test
```

---

## Contributing

We welcome contributions to keep DevTriage clean, fast, and bloat-free. Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on code standards, local testing guidelines, and architectural invariants.

---

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.
