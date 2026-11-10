**What this proposes**

Dispatch replaces its two GitHub feeds — a 45-second search for issues assigned to the user and a 15-minute backfill merged into the same list — with one **Open Work** view backed by a single GitHub search, `is:open involves:@me`, fetched at most four pages of 100 and held in memory. A new `OpenWorkStore` owns the fetch, visible list, hidden keys, status and selection; `SyncCoordinator` keeps one `lastOpenWorkAttempt` timestamp and calls the store from its existing 45-second loop. The visible set is replaced only on a successful run; a failed run keeps rows, the last-success time and hidden keys, and shows an error. Imported items are never unread, get their own sidebar count, and support only "Open on GitHub" and a local, undoable, persisted "Hide." The plan removes the live feed, the merge engine, the smart filters, two dismissal stores, and the free-text owner/repository configuration, moves the PAT to the Keychain, and splits the work into five slices that each compile.

**How the existing system works, per this document**

The GitHub side currently merges a live assigned-issue search, re-emitted every 45 seconds as unread items, with a 15-minute backfill that defaults to `/issues?filter=all` — every open issue the token can see. Per-source fetches swallow errors and return empty arrays, so a partial result replaces the whole list and deletes rows plus the dismissal record for the failed source. Caps are silent (300 per source, 500 by array position, GitHub's 1,000 search ceiling), imported items arrive read, and two dismissal stores keyed differently never see each other's entries. Scope is configured by free-text owner and repository lists run as a union, with malformed lines silently dropped, and the published app is ad-hoc signed and un-notarized.

## Findings

### 1. The first fetch has no call site

* **Severity:** Major
* **Affected Scope:** Refresh and failure (line 191); Views (lines 208–221); items 7 and 10 (lines 390, 409)
* **Discrepancy Description & Rationale:** `noteOpenWorkWorkspaceOpened()` is defined and given behavior, but no numbered item says who calls it. Item 10 changes routing and `MainSplitView`’s choice of view; item 7 only injects the store and coordinator. Every other behavior in the document — the loading state, CUJ 1, the 15-minute loop’s `hasOpenedOpenWork` gate — depends on this one call, and a literal implementer can wire everything except the entry point. Also state whether `hasOpenedOpenWork` ever resets, since as written the loop polls forever after one visit to the workspace.

### 2. The PAT migration deletes the only stored token

* **Severity:** Major
* **Affected Scope:** PAT storage (line 225); item 18 (line 454); NFR Security (line 314)
* **Discrepancy Description & Rationale:** The current app reads `preferencesStore.githubPAT` first and PAT validation writes only to UserDefaults. The design says the migration “deletes the old defaults key if present” and never says it copies the value into the Keychain first. Every existing connected user is silently disconnected on upgrade, and Settings/onboarding — now reading only the Keychain — will report not connected. Specify copy-then-delete and name the trigger (app launch, `PreferencesStore` init, or first Settings open). The same section should reconcile “`repo` only” copy with the compatibility claim that fine-grained tokens work, because fine-grained tokens have permissions, not scopes.

### 3. Dispatch and the retained agent-dispatch path are never defined

* **Severity:** Major
* **Affected Scope:** Overview; component map (line 108); Views (lines 218–219); item 12 (line 419)
* **Discrepancy Description & Rationale:** “Dispatch to agent,” `⌘⇧A` dispatch, `AgentCLI`, `TerminalApp` and “the dispatch payload” are all retained, but the document never says what the app does with an item: which process launches, what the agent receives, or what happens when no agent or terminal is configured. Item 12 says only “Update `dispatchCurrentItem()` to take an `OpenWorkItem`.” The one non-read-only feature the design keeps cannot be implemented from this text. One sentence on the app’s shape and one on the dispatch contract would close it.

### 4. `fetchAction` cannot be held and wired after construction

* **Severity:** Major
* **Affected Scope:** Refresh (line 181); item 4 (line 373); item 7 (line 390)
* **Discrepancy Description & Rationale:** The store “holds” `fetchAction` as a non-optional dependency, while the composition root “wires `openWorkStore.fetchAction`” after creating the store. No initializer signature or mutability is stated. Choose an initializer parameter or a settable property, and say what `refresh()` does if it is called before wiring — Settings validation calls `refresh()` directly, so that ordering is reachable.

### 5. “Complete” is used as a gate but never defined

* **Severity:** Major
* **Affected Scope:** Overview (line 13); Goals (line 37); Refresh (lines 182, 185); Risks (line 328)
* **Discrepancy Description & Rationale:** Three different facts could make a run “complete”: HTTP success, reaching the end of pagination, or `truncated == false`. The term decides whether closed items leave and whether hidden keys are pruned, and the document uses “complete run” and “successful refresh” interchangeably in adjacent bullets. State the boolean once. A fresh reader cannot tell whether a truncated success is allowed to prune.

### 6. The same migration key has two owners in two slices

* **Severity:** Nit
* **Affected Scope:** item 4 (line 373); item 18 (line 454)
* **Discrepancy Description & Rationale:** Slice 2 deletes `dispatch.dismissedGitHubIssueIDs` at store initialization; Slice 5 adds a migration that deletes it again. The earlier deletion makes the later migration dead code, and the PreferencesStore migration’s trigger is never named. Assign the key to one slice.

### 7. `activeWorkspace` is load-bearing but not listed as kept

* **Severity:** Nit
* **Affected Scope:** Views (line 208); item 19 (line 459)
* **Discrepancy Description & Rationale:** Views keeps `activeWorkspace` on `TriageStore` as the routing flag for both stores, while item 19 makes `TriageStore` “Gmail-only” and does not name `activeWorkspace` among the retained properties. An implementer following item 19 can remove the flag that `MainSplitView` and `DetailPaneView` depend on.

### 8. Goal 5’s “running state” has no header element

* **Severity:** Nit
* **Affected Scope:** Goal 5 (line 39); header spec (line 211); Accessibility (line 322)
* **Discrepancy Description & Rationale:** The goal requires the header to show running state, but the header is specified as counts plus a Refresh button. Accessibility says the control “reports its running state,” which could mean a spinner, a label, or a disabled button. The other four header elements are named; this one is not.

### 9. Project components are used as contracts without definition

* **Severity:** Nit
* **Affected Scope:** PAT storage (line 225); item 16 (line 444); item 18 (line 454); Data model (line 144)
* **Discrepancy Description & Rationale:** `AuthService`, `DispatchApp`’s “token provider,” and `GitHubError` are the sole paths for PAT read/write and error mapping, but none is described. `AuthService.hasGitHubPAT()` is qualified with “or an equivalent,” which leaves the API open rather than deciding it. Each needs one clause saying whether it exists, what it exposes, and how `GitHubError` reaches `OpenWorkFetchError`.

### 10. Detail-fetch failures are outside the new failure contract

* **Severity:** Nit
* **Affected Scope:** Views (line 218); NFR Security/network claim (line 314)
* **Discrepancy Description & Rationale:** `fetchIssueDetails` is retained as a second GitHub call, but `OpenWorkFetchError`, `OpenWorkStatus` and the stale banner cover only `fetchOpenWork`. The document’s premise is that GitHub failures stop being silent; say whether a detail 401/403 is shown inline, retried, or leaves the list untouched. Also define “imported” once (old backfill versus new in-memory fetch) and use one name for “live search / live feed / assigned-issue feed.”
