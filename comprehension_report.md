**What this proposes**

Dispatch is a macOS app that shows Gmail and GitHub in one window. This design replaces its two GitHub feeds with a single **Open Work** view backed by one search, `is:open involves:@me`, fetched at most four pages of 100 and held in memory. A new `OpenWorkStore` owns the fetch, visible list, hidden keys, status, selection, refresh clock and last-run summary; `SyncCoordinator`'s existing 45-second loop and wake handler only call `refreshIfDue()`. A `complete` boolean is supposed to decide when rows are replaced, closed items dropped and hidden keys pruned; a failed run keeps rows and shows a classified error. Imported work is never unread, gets a neutral sidebar count, and supports only "Open on GitHub" and a local, undoable, persisted "Hide". The plan also moves the PAT from UserDefaults to the Keychain, removes the live feed, merge engine, smart filters, two dismissal stores and the owner/repository configuration, and sequences the work into five slices that must each compile.

**How the existing system works, per this document**

Today the GitHub side merges a 45-second search for issues assigned to the user with a 15-minute backfill that defaults to `/issues?filter=all`, i.e. every open issue the token can see. Per-repository and per-owner fetches swallow errors and return empty arrays, so one failed source deletes its rows and the dismissal record that protects them; a partial result replaces the whole list. Caps are silent (300 items per source, 500 by array position, GitHub's 1,000 search ceiling), dismissal state lives in two stores keyed differently, and scope comes from free-text owner and repository lists run as a union with malformed lines dropped. Imported items arrive already read, smart filters use hardcoded review and CI values, and the distributed app is ad-hoc signed and un-notarized with an unused Google refresh token.

## Findings

### 1. “Complete” gates the fields that describe an incomplete run

* **Severity:** Blocker
* **Affected Scope:** Overview line 13; Goal 3 line 37; `complete` definition lines 144, 179; Refresh line 190; header lines 221–224
* **Discrepancy Description & Rationale:** Line 190 updates `lastSuccess`, `matchedCount` and `truncated` only inside the `complete` branch, but `complete` requires `!truncated` and `truncated` is true exactly when `matchedCount > 400` or page four has a next link. Therefore a user above 400 matches can never set `truncated`, never advance `lastSuccess`, and never persist a matched count, so Goal 5’s truncation notice and the “X fetched · Y matched (capped)” line cannot render, and the header claims stale data over a fresh fetch. The document also says three times that the list is replaced “only after a complete run” (lines 13, 37) and once that an incomplete run “replace[s] the visible list” (line 190); “the visible list” is undefined relative to `allItems`, the stated source of truth. A fresh reader cannot implement one behavior from this.

### 2. The hidden-key migration runs after the store has already read the key

* **Severity:** Blocker
* **Affected Scope:** Store behavior lines 207–213; Removals line 253; item 4 line 392; item 7 line 411; item 19 line 480
* **Discrepancy Description & Rationale:** Item 7 creates `OpenWorkStore` before “snapshot loading”, and item 4 says the store reads `dispatch.openWorkHiddenKeys`. The seeding of that key happens in item 19 inside `TriageStore`’s snapshot load, which item 7 runs later. Nothing states that the migration must precede store construction, and the store’s first `hide()` then persists an empty set over the seeded one. On upgrade every hidden item returns once and the old hides are destroyed permanently. “Migrate the old hidden state in `TriageStore` before deleting either store” constrains deletion order, not read order.

### 3. The store is created where the environment cannot hold it

* **Severity:** Blocker
* **Affected Scope:** Component map lines 105–115; item 7 line 411; item 10 line 426; item 15 line 456
* **Discrepancy Description & Rationale:** Item 7 constructs the store inside `setupServicesAndSync()`, which runs on appear, then says to “inject the store into the window, Settings and Onboarding”. Items 10 and 15 require `@Environment(OpenWorkStore.self)`, a non-optional lookup that must already be populated when `body` builds the window and Settings scenes. The document never names the owner (`@State` optional, custom `EnvironmentKey`, or lazily resolving closure), and the mandated `fetchAction` initializer parameter plus `GitHubService`’s `AuthService` dependency makes the obvious workaround non-trivial. Slice 3 has no stated construction that compiles, contradicting the plan’s own per-slice gate.

### 4. First-fetch behavior is stated four different ways

* **Severity:** Major
* **Affected Scope:** Goal 3 line 37; CUJ 5 line 94; Refresh lines 188, 195–200; item 8 line 416
* **Discrepancy Description & Rationale:** `refreshIfDue()` refreshes on `!hasFetchedThisLaunch` with no workspace condition, and the 45-second loop calls it, so Open Work fetches within 45 seconds of launch whether or not GitHub was opened. Goal 3 says “on the first open”, CUJ 5 assumes no data before an open, and item 8 asserts “no refresh before the first open”. Line 199 also leaves the open hook’s caller as “`MainSplitView.onChange` or `OpenWorkView.task`”, two different triggers with different launch behavior, while item 12 picks `onChange` — which does not fire when GitHub is already the active workspace at launch.

### 5. Clearing the PAT destroys hides that Goal 8 promises to keep

* **Severity:** Major
* **Affected Scope:** Goal 8 line 42; CUJ 4 line 90; Store behavior line 192; PAT storage line 242; Non-Goals line 54
* **Discrepancy Description & Rationale:** `clear()` “resets items, status, selection, hidden keys and the last-run summary”, while Goal 8 and CUJ 4 say a hide survives until the user restores it. Disconnect is an undocumented third removal path. The Non-Goals also call the “connected state” a persisted thing without saying what it is or where it lives; `isConfigured` is derived from the Keychain, not persisted separately.

### 6. The PAT is kept and deleted in the same paragraph, and one later slice still reads it

* **Severity:** Major
* **Affected Scope:** PAT storage line 240; plan preamble line 368; items 7 and 12 lines 411, 441
* **Discrepancy Description & Rationale:** Item 7 says “keep the defaults key until [items 10 and 11] land”, then, in the same item, copy the value and delete the key. Line 368 says Settings and Onboarding switch “within Slice 5”, but items 10 and 11 are in Slice 3 and Slice 5’s own preamble (line 470) says Slice 3. Meanwhile item 12, in Slice 4, still replaces `isFirstLaunchEmptyState`’s `preferencesStore.githubPAT` read, so between the deletion and item 12 an existing user relaunches with an empty token and sees onboarding. A reader cannot order these three statements.

### 7. `⌘⇧A` dispatch is retained but never described

* **Severity:** Major
* **Affected Scope:** Component map line 111; Views line 231; Alternatives line 325; items 12, 14, 20 lines 441, 451, 485
* **Discrepancy Description & Rationale:** The design keeps `⌘⇧A` dispatch, `dispatchCurrentItem()`, `dispatchToAgent`, `TerminalApp`, `AgentCLI` and “the dispatch payload”, and calls this the one feature that beats `github.com/issues`. It never says which process launches, what the payload contains, what the agent receives, or what happens when no agent or terminal is configured. “Fetches the detail and builds one payload” is the full contract. Two dispatch entry points remain (items 12 and 14), so a fresh engineer must invent the feature that the design’s product argument rests on.

### 8. The status carries no error identity, but the view must branch on it

* **Severity:** Major
* **Affected Scope:** `OpenWorkStatus` lines 148–156; CUJ 2 line 78; Refresh line 191; empty states line 226
* **Discrepancy Description & Rationale:** `OpenWorkStatus` exposes only `errorText: String?`, yet the view must choose “Update token” for 401, “Retry at HH:MM” for 403, and Retry otherwise. String-matching user-facing text is not a contract. `.notConfigured`, `.notFound`, `.decoding` and `.forbidden(resetAt: nil)` have no copy or action; the last is the realistic fine-grained-token case and would render “Retry at nil”.

### 9. `snapshotLoadFailed` has no exit

* **Severity:** Nit
* **Affected Scope:** Removals line 252; NFR line 336; Risks line 347
* **Discrepancy Description & Rationale:** A corrupt file suppresses every save “for that launch”, but nothing renames, quarantines or rewrites it, so every later launch fails identically and Gmail state stops persisting with no recovery described.

### 10. “Imported” names two different things

* **Severity:** Nit
* **Affected Scope:** lines 13, 25, 27, 54, 126, 501
* **Discrepancy Description & Rationale:** “Imported” means the old backfill in the Problem and the new in-memory fetch in the Goals, data model and coverage matrix; “live search” and “live feed” are likewise interchangeable. The invariant “imported work never affects Gmail unread counts” therefore has no fixed subject.

### 11. The snapshot is load-bearing and never described

* **Severity:** Nit
* **Affected Scope:** lines 126, 251–253, 295, 336, 521
* **Discrepancy Description & Rationale:** The rollback check asks the reader to “load a snapshot written by the current release”, and the migration decodes and rewrites it, but the document never says what the snapshot is, where it is stored, when it is written, or how to produce one. `SnapshotData` and `TriageStore` are assumed rather than introduced.

### 12. The unread invariant is tested where it cannot be asserted

* **Severity:** Nit
* **Affected Scope:** item 5 line 397; coverage matrix line 501
* **Discrepancy Description & Rationale:** “Imported work never affects Gmail unread counts” is assigned to `OpenWorkStoreTests`, but the document also states the two stores never read each other, so the store under test cannot observe a Gmail count. Either the invariant belongs in `TriageStoreTests` or the matrix names no owner for the integration it claims to prove.

*Previously fixed and not re-raised: fetch pagination and error contract, PAT copy-before-delete, attempt stamping and single-flight, header variants, slice test ordering, `activeWorkspace` retention, `fetchAction` as an initializer parameter.*
