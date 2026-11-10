# Stage 8 Review Report: Intermediate Zoom Out (Post-Resolution)

* **Target:** `docs/designs/github_open_work.md` (499 lines)
* **Reviewer:** `egm-zoom-out` (Skeptical Architect)
* **Standard:** `resources/document_standards/zoom-out-standard.md`
* **Mode:** REVIEW — read-only
* **Classification:** (a) design change required · (b) specification only · (c) accept as trade-off

---

## Verdict

The revision is now proportionate: one query, one store, one list, and a plan dominated by deletions. Approve the direction; block on contract gaps, not architecture.

Three objections must be fixed before implementation:

1. **The completeness contract is not complete.** The design prunes hidden keys on any “successful” run, but a capped or 404-short-circuited run is successful and incomplete. That resurrects hidden work, the exact failure Goal 4 and CUJ 2 promise to prevent.
2. **Cold start can skip the only fetch.** A persisted summary younger than 15 minutes suppresses the first fetch of the launch, leaving an empty list under a header that says “refreshed 5m ago”.
3. **The attempt clock is not an attempt clock.** It is reset on success only (line 193), so a failing refresh retries every 45 seconds and violates the stated revoked-PAT mitigation (line 327). The manual-success reset also has no path to the coordinator, which “never reads store state” (line 249).

---

## Blocker Findings

### B1 — Pruning on an incomplete “success” (a)

**Scope:** lines 171, 182, 185, 328; `GitHubService.requestAllPages` (`GitHubService.swift:336-357`).

`truncated` is the only completeness signal, but pruning is gated on success, not on `truncated`. A run that stops at 400 items is “complete enough” to replace `allItems` but not to prune hidden keys: an item beyond the cap disappears this run, its key is deleted, and it reappears visible next run. Separately, the reused helper returns pages so far on a 404 (`line 347`), producing a partial array that can set `truncated == false`. Define `complete = !truncated && pagination ended naturally`, prune only when `complete`, and either pass a `stopOn404: false` adapter or remove the helper’s 404 short-circuit for this call. Do not derive completeness in three places (lines 171, 182, 185).

### B2 — Persisted summary can suppress the first fetch (a/b)

**Scope:** lines 154, 190–191; CUJ 1 (line 70), CUJ 5 (lines 92–94).

`noteOpenWorkWorkspaceOpened()` refreshes “if the last success is nil or older than 15 minutes”. After relaunch with `lastSuccess` 5 minutes old from the summary, no fetch runs, `allItems` is empty, and the header reports a fresh timestamp. Gate the first-of-launch fetch on `allItems.isEmpty` (or an explicit `hasFetchedThisLaunch`), not on the persisted success time. The summary is display-only.

### B3 — Failed attempts are not throttled; manual success cannot reset the clock (a)

**Scope:** lines 187–193, 249; risk at line 327.

`lastOpenWorkAttempt` is described as an attempt but only reset on success. A revoked PAT produces four requests per failed run, every 45 seconds, contradicting “do not loop faster than the 15-minute cadence”. Also, `openWorkStore.refresh()` is the only manual path and the coordinator holds no completion channel, so “a manual success resets `lastOpenWorkAttempt`” is unimplementable as written. Update the timestamp before or immediately after every attempt, success or failure.

---

## Major Findings

### M1 — Two owners for one refresh clock (a)

**Scope:** component map (lines 110–111), lines 118, 154, 187–193, 249.

The store owns `lastSuccess`, the fetch and error state; the coordinator owns `lastOpenWorkAttempt`, `hasOpenedOpenWork`, and “loads the persisted last-run summary”. That is three representations of one fact, a summary reader in a component that never reads store state, and the reset contradiction above. Collapse it: the store owns `lastAttempt`, `hasOpened`, hydration of the persisted summary, and `refreshIfDue(force:)`. The coordinator’s 45-second loop and workspace-open hook call that one method. This removes `hasOpenedOpenWork` and the summary load from the coordinator and changes no user-facing decision.

### M2 — PAT migration lands after the reader switch (a)

**Scope:** line 390 (Slice 3), lines 225, 454 (Slice 5).

Slice 3 makes `DispatchApp` read the Keychain only; the defaults-key migration is in Slice 5. Current validation does write the Keychain (`AuthService.swift:518`), so most installs survive, but any prefs-only install loses GitHub for two slices. A slice boundary that compiles while silently disabling a source is not a safe boundary. Move the migration into Slice 1 or 3. Also pick one migration site: Slice 2’s store-init deletion (line 373) and `PreferencesStore` (line 454) currently both claim `dispatch.dismissedGitHubIssueIDs`.

### M3 — The retained dispatch path is asserted, not specified (b)

**Scope:** lines 218–219, 409.

`OpenWorkItem` has no body; `MainSplitView.dispatchCurrentItem()` currently builds `body: item.title`, while `DetailPaneView` uses the fetched `gitHubDetail`. The plan says update `dispatchCurrentItem()` to take an `OpenWorkItem` but does not say where the body comes from on the shortcut path. State whether `Cmd+Shift+A` uses the selected item’s cached detail (and what happens before it loads) or deliberately sends title-only. Keep one payload builder, not two.

### M4 — “Await the in-flight call” has no mechanism (b)

**Scope:** line 184, tests at line 395.

Swift has no ambient in-flight call to await. Specify a stored `refreshTask: Task<…, Never>?`; every caller awaits that task and no second request starts. The coordinator test and the store coverage row depend on this contract.

### M5 — Reuse claim does not match the helper (b)

**Scope:** lines 168, 361.

`requestAllPages` requires `context:` and returns raw pages; the plan’s call shows neither. Specify the call shape and how `total_count` is read from page one while the helper owns pagination, or the “reuse” note invites a second pagination loop.

## Nits

* **N1 — `OpenWorkFetchError` duplicates `GitHubError` (b).** One-to-one cases existing solely to be rendered as `errorText` is a second taxonomy. Either add user copy to `GitHubError` or justify the boundary in one sentence.
* **N2 — Successful refresh can kill the Undo banner (a, small).** `lastHiddenKey` cleared by a successful refresh (line 202) can delete the key while its 5–8 second banner is still on screen. Let the banner own its dismissal; drop `lastHiddenKey`.
* **N3 — Status duplicates store state (b).** `OpenWorkStatus` carries `matchedCount` and `truncated`, which the store already holds and persists. One `LastRun` struct (timestamp, matched, truncated, error) removes the mirror.
* **N4 — Global empty state changed silently (b).** Line 409 changes `isFirstLaunchEmptyState` to span both workspaces. Verify this is intended; it is a product-visible change hidden in a routing step.

---

## Keep / Simplify / Drop

**Keep**

* One `involves:@me` query; no owner/repository fan-out; no new dependency.
* Separate `OpenWorkItem` and `OpenWorkStore`; the Alternative A2 reasoning is sound.
* In-memory items with only hidden keys and a last-run summary persisted.
* 400 cap with explicit truncation copy; 15-minute due check on the existing 45-second loop.
* Removals list, tolerant snapshot decoder, `didLoadSnapshot`, Keychain-only PAT.
* Five-slice outline: the dependency order (views before model deletion) is real, not ceremony.

**Simplify**

* Timestamp ownership → store (`refreshIfDue`); coordinator calls one method.
* One migration site, before the Keychain-only reader.
* One error-to-copy mapping; one `LastRun`; one dispatch payload builder.
* Prune rule stated once as `complete`, not re-derived at lines 171, 182 and 185.

**Drop**

* Coordinator `hasOpenedOpenWork` and its persisted-summary load.
* `lastHiddenKey` as store state.
* The parallel `OpenWorkFetchError` enum unless it earns its keep with user-facing copy.

**Accept as trade-off (c)**

* `activeWorkspace` on `TriageStore` routing two stores. Slightly wrong owner, but moving it costs more than it buys now.
* No hidden-items sheet; “Restore all hidden (N)” is blunt but matches the stated v1 scope.
* Unbounded hidden keys; bounded by user actions, pruned only on complete runs.
