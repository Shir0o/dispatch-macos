# Stage 5 Review Report: Initial Zoom Out Review

* **Target Document:** `/Users/twang/dev-triage-macos/docs/designs/dev_triage_macos.md`
* **Scope:** Lines 1..414 (Full File)
* **Reviewer:** `egm-zoom-out` (Skeptical Architect)
* **Standard:** `resources/document_standards/zoom-out-standard.md`
* **Mode:** REVIEW

---

### Finding 1: Sandbox Violation & Terminal Execution Contradiction
* **Severity:** 🔴 Blocker
* **Affected Scope:** Section 2.E (Lines 168–185), Non-Functional Requirements (Line 293), Target Files (Lines 355–358)
* **Simplicity Rationale:** The design mandates strict App Sandbox enforcement (`com.apple.security.app-sandbox` with network restricted to Google and GitHub), but proposes having `AgentDispatchService` script external terminal emulators (Terminal.app, iTerm2, Ghostty), execute CLI binaries (`claude`, `opencode`, `antigravity`), and access local repository working directories. Under macOS App Sandbox, a process cannot send arbitrary AppleEvents, launch external terminal scripts with dynamic command strings, or access arbitrary filesystem paths outside its sandbox container without temporary exception entitlements or security-scoped bookmarks. Furthermore, line 173 mentions local repo paths being "mapped via user preferences by repository name," but no preferences UI, settings model, or file bookmark storage is specified anywhere in the design.
* **Simpler Alternative:** Keep the application strictly sandboxed by having `Cmd+Shift+A` format the structured prompt and copy it directly to the system clipboard (with an unobtrusive toast notification: *"Prompt copied to clipboard"*), while optionally revealing the configured directory via `NSWorkspace.shared.activateFileViewerSelecting` or opening the terminal app without injecting raw script commands.

---

### Finding 2: Premature Dual-Protocol GitHub Layer (GraphQL + REST with Zero Dependencies)
* **Severity:** 🟡 Major
* **Affected Scope:** Section 2.B (Lines 140–143), Target Files (GitHubService, Lines 341–346)
* **Simplicity Rationale:** The document establishes an invariant of **zero external dependencies** (no Apollo or third-party GraphQL client), yet introduces a dual-protocol architecture requiring GitHub GraphQL for batching PR check suites and comment counts on top of standard REST `/notifications`. Constructing, escaping, and serializing raw GraphQL query strings with `Foundation.URLSession` and manually parsing deeply nested dynamic JSON responses without a code-generated GraphQL client creates fragile, error-prone boilerplate.
* **Simpler Alternative:** Stick entirely to GitHub's REST API v3. For PR status checks, query `/repos/{owner}/{repo}/commits/{ref}/check-runs` or inspect the pull request REST resource directly on demand. Eliminating GraphQL removes a redundant protocol layer and cuts network parsing complexity in half.

---

### Finding 3: Premature 500-Item LRU Eviction Engine for an In-Memory List
* **Severity:** 🟡 Major
* **Affected Scope:** Section 2.C (Lines 150–152), Target Files (TriageStore & Tests, Lines 325, 384–385)
* **Simplicity Rationale:** The design proposes implementing a custom Least-Recently-Updated (LRU) eviction algorithm inside `TriageStore` and writing dedicated unit tests for it (`TriageStoreTests.swift`). An array of 500 lightweight Swift structs (`TriageItem` containing strings, date, and booleans) consumes under 100 KB of RAM. A triage feed is chronological; capping an in-memory list to 500 items can be accomplished with a single line (`Array(items.prefix(500))`) or date-based filtering. Building, maintaining, and testing an LRU eviction data structure for a basic presentation store is premature optimization and violates YAGNI.

---

### Finding 4: Ambiguous State Mutation Flow Between TriageStore and SyncCoordinator
* **Severity:** 🟡 Major
* **Affected Scope:** Section 1 (Architecture Diagram, Lines 79–122), Section 2.C (Lines 153–156)
* **Simplicity Rationale:** There is an architectural contradiction in state mutation ownership. In the Mermaid diagram, `SyncCoordinator` exclusively owns the network clients (`GmailService`, `GitHubService`, `AuthService`) and unidirectionally feeds state into `TriageStore`. However, the text states that when `e` (archive) is pressed, `TriageStore` performs optimistic local removal and directly executes `users.messages.modify` or `PATCH /notifications/threads/{id}`. If `TriageStore` communicates directly with external REST services, the dependency diagram is inaccurate. If mutations must pass back through `SyncCoordinator`, the coordinator's mutation interface is completely omitted. Service ownership and mutation data flow must be unified and explicit.

---

### Finding 5: Missing First-Run Credential Configuration and Onboarding Flow
* **Severity:** 🟡 Major
* **Affected Scope:** Section 2.A (Lines 128–132), Target Files (Lines 307–391)
* **Simplicity Rationale:** The design thoroughly documents low-level PKCE OAuth cryptographic primitives and Keychain storage flags, but completely ignores how the user configures the application. Because DevTriage is an open-source client requiring personal Google Cloud Desktop OAuth Client IDs or GitHub Personal Access Tokens (as noted in README.md), the lack of any onboarding screen, credentials entry view, or configuration state machine is a critical functional omission. The technical plan should outline a minimal setup view or empty-state authentication card before jumping into background sync engines.

---

### Finding 6: Speculative Randomized Polling Jitter
* **Severity:** 🟢 Nit
* **Affected Scope:** Section 2.B (Lines 148–149)
* **Simplicity Rationale:** Adding "±5-second randomized jitter" to a 45-second timer to "avoid rhythmic network bursts" is a distributed systems pattern designed to prevent thundering herd problems across large fleets of client machines. A single local macOS desktop client making one request every 45 seconds to Google and GitHub's infrastructure does not need randomized timer jitter. A standard `Task.sleep(for: .seconds(45))` loop is simpler and eliminates artificial timing logic.

---

### Finding 7: Unnecessary Single-Use Abstractions (`SnapshotManager`) & Prompt Logic in Domain Models
* **Severity:** 🟢 Nit
* **Affected Scope:** Target Files (`SnapshotManager.swift`, Lines 351–354), Domain Model (`AgentDispatchPayload`, Lines 220–240)
* **Simplicity Rationale:** Creating a separate file and class (`SnapshotManager.swift`) solely to read and write a single JSON file on launch and termination violates the "no abstractions for single-use code" principle. Encoding and decoding an array of `TriageItem` to `Application Support` can be implemented directly as two private helper functions on `TriageStore`. Additionally, in `TriageItem.swift`, embedding markdown prompt string interpolation inside the core domain entity struct introduces presentation formatting concerns into the data model layer. Prompt assembly belongs in the dispatch utility.

---

### Finding 8: Misleading "Full MIME Parsing" Terminology
* **Severity:** 🟢 Nit
* **Affected Scope:** Target Files (`GmailService.swift`, Line 337)
* **Simplicity Rationale:** Line 337 states that `GmailService` implements "Full MIME parsing (base64url decoding, multipart/alternative extraction)". The Gmail REST API (`users.messages.get` with `format: .full`) already provides a parsed JSON tree with headers and MIME part breakdown. Describing this as writing a "Full MIME parser" suggests unnecessary low-level RFC 2822 parsing weeds. The document should simply specify extracting the HTML body part from the Gmail JSON payload and base64url decoding the string.
