# Dispatch for macOS

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](https://apple.com/macos)
[![Language](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Download](https://img.shields.io/badge/download-latest%20release-brightgreen.svg)](https://github.com/Shir0o/dispatch-macos/releases/latest)

> A lightweight, open-source native macOS triage client for Gmail and GitHub. Zero Docker containers. Zero Electron runtimes. Sub-50ms interaction latency.

---

## Installation

Grab the latest build from [GitHub Releases](https://github.com/Shir0o/dispatch-macos/releases/latest):

1. Download the latest `Dispatch-<version>.dmg`.
2. Open the disk image and drag **Dispatch** into **Applications**.
3. Launch Dispatch from Applications.

Requires macOS 14 (Sonoma) or newer. Releases are universal builds for Apple silicon and Intel Macs.

> [!NOTE]
> Releases are currently ad-hoc signed (not notarized). If macOS blocks the first launch, right-click the app and choose **Open**, or clear the quarantine flag with `xattr -dr com.apple.quarantine /Applications/Dispatch.app`.

---

## The Vision

Software developers are constantly context-switching between asynchronous personal/work email and GitHub activity (code reviews, assigned issues, and CI failure alerts). Existing options present significant trade-offs:

* **Resource Bloat:** Web-wrapped clients (Electron) and containerized self-hosted sync engines consume 500 MB to 4 GB of RAM, running persistent background Linux VMs that quickly drain laptop batteries.
* **Dated Desktop Clients:** Traditional desktop mail clients either lack Gmail-native label tag semantics (forcing multi-folder duplication via IMAP) or offer zero integration with GitHub issue and PR triage.
* **Fragmented AI Workflows:** When running local AI coding agents (Claude Code, OpenCode, Antigravity) in the terminal, developers lose track of issue reproduction details and context when the agent asks clarifying questions.

**Dispatch** is a native Swift 6 and SwiftUI client engineered specifically for rapid developer triage.

---

## Key Features

* **Authentic Native macOS Performance:** Built with pure SwiftUI (`NavigationSplitView`) and AppKit integration. Sub-50ms response times for keyboard triage and an idle memory footprint under 50 MB.
* **Stream Isolation:** Dedicated workspaces for **Gmail** and **GitHub**, preventing developer noise and CI alerts from polluting personal correspondence.
* **Vim/Superhuman Keyboard Navigation:**
  * `j` / `k`: Next / Previous item
  * `e`: Archive email in Gmail, or hide an item in Open Work
  * `s`: Star / pin an email (Gmail only)
  * `u`: Mark unread (Gmail only)
  * `#` or `Delete`: Trash / unsubscribe (Gmail only)
  * `Cmd+O`: Open the selected email or Open Work item in your browser
  * `Cmd+Shift+A`: Dispatch the selected item to a local coding agent
  * `Cmd+Z`: Undo the last Open Work hide while the banner is visible
* **Non-Destructive Invariant:** Fast triage (`e`) archives personal inbox messages or hides Open Work locally. It **never** mutates public GitHub issue states (closing an issue remains an explicit action).
* **GitHub Open Work:** One involvement query replaces both the notification feed and the backfill. Dispatch imports every open issue and pull request involving you — authored, assigned, mentioned, or commented on — groups it by repository, and refreshes it every 15 minutes after you first open the workspace. There is no repository configuration, no unread state, and no silent truncation. See [GitHub Open Work](#github-open-work).
* **Local Coding Agent Dispatch (`Cmd+Shift+A`):**
  * Bundles issue title, reproduction steps, comments, labels, and local repo paths into a structured markdown prompt.
  * Dispatches the prompt to `NSPasteboard.general` and activates your configured local CLI agent (`claude`, `opencode`, `antigravity`) in your favorite terminal or IDE (Terminal, iTerm2, Ghostty, VS Code).
  * Pins the issue details side-by-side in Dispatch so you can answer agent clarifying questions without opening browser tabs.
* **WebKit Isolation & Security:**
  * Single recycled `WKWebView` instance in the detail pane.
  * JavaScript execution strictly disabled (`allowsContentJavaScript = false`).
  * Remote tracking pixels blocked by default with declarative CSP `<meta>` tags.
  * Dark mode CSS automatically injected.
* **Zero Container / Zero Daemon Overhead:** Runs completely standalone. Cold start loads instantly from an ephemeral quit snapshot (`snapshot.json`). Tokens stored securely in the macOS Keychain.

---

## GitHub Open Work

The GitHub workspace is one **Open Work** list, not a notification inbox. It runs one GitHub search — `is:open involves:@me`, sorted by most recently updated — and holds the result in memory.

* **Scope:** every open issue and pull request this token can read that involves the authenticated user: authored, assigned, mentioned, or commented on.
* **Not included:** subscription-only items and review requests that do not otherwise involve you. GitHub's `involves:@me` qualifier does not cover them, so they will not appear.
* **Refresh:** the first time you open the GitHub workspace in a launch, Dispatch fetches immediately; after that it refreshes every 15 minutes while the app is running. The header's Refresh button is always available.
* **No unread state:** imported work is never counted as unread. The GitHub sidebar row shows a neutral “N open items” count, not a badge.
* **Grouping:** items are grouped by repository, newest first, with a visible count per repository. This version has no search box, kind filter, or repository-level hide.
* **400-item cap:** Dispatch fetches at most 400 items and follows at most four pages. When more work matches, the header discloses how many were fetched and how many matched; GitHub itself reports at most 1,000. A truncated success still replaces the list but never drops hidden keys.
* **Failures keep the list:** a failed refresh leaves the previous items, counts, and last-success time in place, keeps hidden items hidden, and shows the matching action — “Update token” for 401, “Retry at HH:MM” for a 403 with a reset time, “Update token” for a 403 without one, and “Retry” for server, decoding, transport, and not-found errors. A first-run failure shows the error instead of an empty “caught up” state.
* **Hiding is local:** “Hide from Open Work” (`e`) removes a row on this Mac, persists the key across relaunch, and offers Undo for six seconds (`Cmd+Z` also works while the banner is alive). There is no per-item restore; “Clear all hidden keys” is the bulk inverse. Hidden keys are keyed on `owner/repo#number`, so a repository rename or transfer can resurrect an old hide.
* **Detail and dispatch:** the detail pane shows the issue or pull request body and comment timeline, “Open on GitHub”, “Hide from Open Work”, and `Cmd+Shift+A` dispatch. If the detail fetch fails, the alert offers “Send title only” so the prompt still goes out.
* **Tokens:** a classic PAT with `repo` read scope sees the full involvement set. Fine-grained PATs and SSO-protected organizations may return a smaller set; the view states that the scope is whatever the token can read. Explicit fine-grained and SSO support is a documented v1 limitation.

### Shortcuts

| Key | Gmail | GitHub Open Work |
| --- | --- | --- |
| `j` / `k` | Next / previous message | Next / previous item |
| `e` | Archive | Hide from Open Work |
| `s` | Star | Not available in Open Work |
| `u` | Mark unread | Not available in Open Work |
| `#` | Trash / unsubscribe | Not available in Open Work |
| `Cmd+O` | Open in Gmail | Open on GitHub |
| `Cmd+Shift+A` | Dispatch to agent | Dispatch to agent |
| `Cmd+Z` | — | Undo the last hide while the banner is visible |

---

## Technical Architecture

Dispatch is structured around Swift 6 structured concurrency and isolated background actors:

```mermaid
flowchart TD
    subgraph UI ["Presentation Layer (SwiftUI / AppKit)"]
        SidebarView["SidebarView (NavigationSplitView)"]
        StreamView["TriageStreamView (LazyVStack / List)"]
        OpenWorkView["OpenWorkView (Grouped List)"]
        DetailView["DetailPaneView (SwiftUI + Recycled WKWebView)"]
        KeyHandler["KeyboardShortcutModifier (Vim/Superhuman + FocusGuard)"]
    end

    subgraph State ["State & Coordination Layer"]
        PreferencesStore["PreferencesStore (@Observable)"]
        TriageStore["TriageStore (@Observable @MainActor)"]
        OpenWorkStore["OpenWorkStore (@Observable @MainActor)"]
        SyncCoordinator["SyncCoordinator (Swift Actor)"]
        AgentDispatch["AgentDispatchService (Clipboard & App Activator)"]
    end

    subgraph Services ["External Network & Security Layer"]
        AuthService["AuthService (ASWebAuthenticationSession + Keychain)"]
        GmailService["GmailService (REST API + users.threads)"]
        GitHubService["GitHubService (REST API v3 /search/issues)"]
        PathMonitor["NWPathMonitor (Network Reachability)"]
        WorkspaceMonitor["NSWorkspace (Sleep / Wake Notifications)"]
    end

    KeyHandler -->|Triage Action| TriageStore
    KeyHandler -->|Open Work Action| OpenWorkStore
    TriageStore --> StreamView
    OpenWorkStore --> OpenWorkView
    StreamView --> DetailView
    OpenWorkView --> DetailView
    SidebarView --> TriageStore
    SidebarView --> OpenWorkStore

    TriageStore <-->|Load / Save Gmail Snapshot (Atomic Synchronous)| DiskStorage["~/Library/Application Support/Dispatch/snapshot.json"]
    TriageStore -->|Optimistic Archive / Star / Trash| GmailService
    OpenWorkStore -->|One Involvement Search| GitHubService
    OpenWorkStore <-->|Hidden Keys| HiddenKeys["UserDefaults (dispatch.openWorkHiddenKeys)"]
    TriageStore <-->|Dispatch Trigger| AgentDispatch
    OpenWorkStore <-->|Dispatch Trigger| AgentDispatch
    AgentDispatch -->|Copy Prompt| Pasteboard["NSPasteboard.general"]
    AgentDispatch -->|Activate App| ExternalTerminal["External Terminal / IDE"]

    SyncCoordinator -->|Deliver Gmail Items| TriageStore
    SyncCoordinator --> GmailService
    SyncCoordinator -->|Refresh If Due| OpenWorkStore
    SyncCoordinator --> AuthService

    PathMonitor --> SyncCoordinator
    WorkspaceMonitor --> SyncCoordinator
    AuthService --> Keychain["macOS Keychain (Security.framework)"]
    GmailService --> GmailAPI["Google Gmail REST API"]
    GitHubService --> GitHubAPI["GitHub REST API v3"]
```

For complete technical specifications, data schemas, and design trade-offs, see the [Technical Design Document](docs/designs/dev_triage_macos.md).

---

## Project Structure

```
dispatch-macos/
├── Package.swift                    # SPM manifest (zero external dependencies)
├── Dispatch.entitlements            # App Sandbox & network client entitlements
├── Info.plist                       # Bundle metadata & OAuth redirect scheme
├── version.txt                      # Release version (bumped by Release Please)
├── release-please-config.json       # Release Please configuration
├── .release-please-manifest.json    # Last released version
├── .github/
│   └── workflows/
│       └── release.yml              # Release Please + DMG build & GitHub Release
├── Sources/
│   └── DispatchApp/
│       ├── App/                     # Application lifecycle & composition root
│       ├── Models/                  # Domain entities (TriageItem, OpenWorkItem, OpenWorkPresentation)
│       ├── State/                   # Bounded in-memory observable stores & preferences
│       ├── Services/                # Gmail, GitHub, Auth, SyncCoordinator, OpenWorkDispatcher, AgentDispatch
│       └── Views/                   # NavigationSplitView, Stream, Detail & RecycledWKWebView
├── Tests/
│   └── DispatchAppTests/            # Concurrency, state machine, and parsing unit tests
├── scripts/
│   ├── package-app.sh               # Release build, bundle assembly & code-signing
│   └── create-dmg.sh                # Drag-to-install DMG packaging
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
* **GitHub Personal Access Token:** Classic token with `repo` read scope. Fine-grained tokens work, but may return a smaller result set scoped to what the token can read.

### Build and Package

```bash
# Clone the repository
git clone https://github.com/Shir0o/dispatch-macos.git
cd dispatch-macos

# Build debug executable and run the test suite
swift build --build-tests
swift test --no-parallel

# Package and code-sign the release app bundle (build/Dispatch.app)
./scripts/package-app.sh

# Build a universal (arm64 + x86_64) bundle and turn it into a DMG
UNIVERSAL=1 ./scripts/package-app.sh
./scripts/create-dmg.sh
```

`package-app.sh` accepts `VERSION`, `BUILD_NUMBER`, `UNIVERSAL=1`, `BUILD_DIR`, and `SIGN_IDENTITY` environment overrides. For local signing, copy `scripts/signing.local.example` to `scripts/signing.local` and set your certificate identity there; that file is git-ignored, and without it builds stay ad-hoc signed like CI. `create-dmg.sh` writes a compressed `Dispatch-<version>.dmg` next to the app bundle, with an `Applications` shortcut for drag-to-install.

---

## Releasing

Releases are automated with [release-please](https://github.com/googleapis/release-please) and [`.github/workflows/release.yml`](.github/workflows/release.yml).

1. Land changes on `main` using [Conventional Commits](https://www.conventionalcommits.org/): `fix:` → patch, `feat:` → minor, `feat!:` or `BREAKING CHANGE:` → major.
2. Release Please opens or updates a **release PR** (`chore: release x.y.z`) that bumps `version.txt` and `Info.plist` and updates `CHANGELOG.md`.
3. Merge the release PR. The same workflow run runs the test suite, builds a universal `Dispatch.app`, stamps the version, signs it, verifies `Dispatch-x.y.z.dmg`, and attaches the DMG plus a SHA-256 checksum to the GitHub Release.

> [!NOTE]
> If release PRs are not being opened, enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**.

Manual releases are still supported: push a `v<semver>` tag (`git tag v1.0.1 && git push origin v1.0.1`), or run the **Release** workflow from the Actions tab with a version number. Suffixed versions such as `v1.1.0-beta.1` are published as pre-releases.

By default the DMG is ad-hoc signed. To enable Developer ID signing and Apple notarization, add these repository secrets:

| Secret | Purpose |
|---|---|
| `MACOS_CERTIFICATE` | Base64-encoded `.p12` Developer ID Application certificate |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Any random password for the temporary CI keychain |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

---

## Contributing

We welcome contributions to keep Dispatch clean, fast, and bloat-free. Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on code standards, local testing guidelines, and architectural invariants.

---

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.
