# Zoom Out Review — `docs/designs/github_open_work.md` (post-resolution)

**Verdict: not ready to hand off.** The two blockers that shaped the last review are gone in substance, but the document still cannot be executed without an implementer inventing three decisions. The remaining defects are small and local, not structural. Fix the two blockers and the “complete” definition, and it is handoff-ready.

## Blockers

### B1. The removal lists still leave live callers — Slice 5 will not compile

The document’s own rule (line 349: “No slice leaves the tree in a state where a removed symbol still has a caller”) is violated by symbols the plan deletes:

* `MainSplitView.swift:37` reads `preferencesStore.githubPAT`. Item 10 (line 409) only replaces the `store.gitHubItems.isEmpty` clause, and item 18 deletes `githubPAT`. No numbered item touches line 37.
* `SettingsView.swift:51` pre-fills `tempGitHubPAT` from `preferencesStore.githubPAT`, and `:143` clears it. Item 16 removes the backfill section and the connected check, not these two reads.
* `DispatchApp.swift:89-93` calls `coordinator.setOnBackfillUpdated`. Item 7 (line 390) removes the notification listener and `setBackfillConfiguration`, but not this closure.
* `TriageStore.loadSnapshot` (`:318-319`) assigns `gitHubItems` and `dismissedGitHubKeys`. Item 19 removes the properties and the writer but never names the loader.

Each is a one-line edit. The problem is that the plan claims to enumerate them and does not, so a literal implementer breaks the build in the last slice — exactly the failure the five-slice order exists to prevent.

### B2. The freshness contract is still two-owner at the edges

The store now owns fetch and status, and `OpenWorkUpdate` is gone. Two leftovers remain:

* **A failed attempt is never timestamped.** Lines 190 and 193 describe `lastOpenWorkAttempt` as being set by success only. If a 401 leaves the timestamp stale, the 45-second loop retries every 45 s — contradicting Goal 3 and line 327 (“do not loop faster than the 15-minute cadence”). “Attempt” must be stamped *before* the closure runs, independent of outcome.
* **“A manual success resets `lastOpenWorkAttempt`” (line 193) contradicts line 249** (“[the coordinator] never reads store state”). The Refresh button calls `store.refresh()` directly, so the actor cannot learn the outcome. Either drop the reset rule (accept up to 15 minutes of drift) or route the button through `coordinator.refreshOpenWorkNow()`.
* Line 191 has `noteOpenWorkWorkspaceOpened()` “load the persisted last-run summary” — the coordinator hydrating `OpenWorkStatus` is the same second-author problem in miniature, and it can overwrite fresher in-memory state on every workspace switch. The store should hydrate in `init`; the coordinator should only set `hasOpenedOpenWork`.

## Major Findings

### M1. “Complete” is undefined, and hidden keys are pruned on a truncated fetch

The document uses “complete run” (lines 13, 37, 182, 185, 328) and “successful refresh” interchangeably but never defines whether `truncated == true` counts as complete. At >400 matches, pruning “keys absent from the complete result” (line 182) drops hidden keys for items outside the 400 window; those items resurrect later when they climb into the window — the failure Goal 45 promises not to allow. State: replace on success; prune hidden keys and drop closed items only when `!truncated`; a truncated run leaves hidden keys untouched.

### M2. Reused `requestAllPages` treats 404 as success

Line 168 says to reuse the helper; `GitHubService.swift:347-349` returns `pages` (possibly empty) on 404 instead of throwing. On the single involvement query, a 404 on page 1 yields zero pages and a 404 on page 2 yields a partial set — both applied as a “complete” result, which empties the list and prunes hidden keys. Either pass a strict variant, or the slice must state that any non-2xx fails the refresh.

### M3. `total_count` has no carrier after the cleanup

`requestAllPages` returns `[Data]` (`:336-357`), `OpenWorkIssuePayload` is a flat issue record, and `OpenWorkSearchResponse` — the only search wrapper — is deleted (`line 231`). Line 361’s “read page one’s `total_count`” needs a decode type. Keep `OpenWorkSearchResponse` and add `total_count`, rather than inventing one silently.

### M4. Truncation still false-positives at exactly 400

Line 171 sets `truncated` when page 4 returns 100 items. With exactly 400 matches that is a complete set, yet the header renders “Showing 400 of 400 (capped)”. `matchedCount > 400` alone is correct and sufficient (GitHub caps `total_count` at 1,000); drop the page-length clause or require the page-4 `Link: rel="next"`.

### M5. `didLoadSnapshot` breaks the first-run save

Item 19 adds a flag that suppresses `saveSnapshotSync` after a decode failure. `loadSnapshot()` returns early when no file exists (`TriageStore.swift:309-310`), before any decode. A flag that starts `false` therefore suppresses the very first save on a fresh install. Define it as “load attempted and failed,” i.e. set `true` when the file is absent, and test the no-file case.

### M6. `isFirstLaunchEmptyState` still hides the screen the design is about

Line 409 replaces the GitHub-emptiness test with `openWorkStore.visibleCount == 0`, so onboarding overlays a connected but legitimately empty Open Work view (and briefly, during the first fetch) whenever Google is unconfigured. The condition should test configuration (Keychain token), not item count — and that is also where B1’s line 37 belongs.

### M7. The product value is still unstated

Goals 1–10 describe correctness, not why a user opens this instead of `github.com/issues`. Alternative H says it “remains the fallback if Open Work cannot name a task it does better” — the document never names it. The differentiators are one window with Gmail, repository grouping, hide, and `⌘⇧A` dispatch. Put that in one sentence in the Overview; the Alternatives section is otherwise defending a feature with no stated job.

## Nits

* **N1.** Item 6 (line 385) files `GitHubService` method removals under `SyncCoordinator.swift`. Move them to item 2 or a new item; as written it invites deleting symbols in the wrong slice.
* **N2.** `OpenWorkFetchResult` (lines 138–142) never declares `Sendable`, though it crosses the actor boundary. `OpenWorkItem` and `OpenWorkFetchError` do.
* **N3.** “Wake triggers one due check” (line 192) is false in the current code: `handleSystemDidWake` restarts the loop (first tick after 45 s) and calls `performSyncCycle` (`SyncCoordinator.swift:360-368`). Either add `refreshOpenWorkIfDue()` to wake or drop the claim and the matching test in item 8.
* **N4.** `fetchAction` closure injection is a new seam; `TriageStore` injects services and tests already use a URL-protocol stub. A stored `GitHubService` would match the codebase for the same testability.
* **N5.** `errorText: String?` plus `OpenWorkFetchError` keeps two representations of one failure. Map once in the store.
* **N6.** `hiddenCount` / “Restore all hidden (N)” counts persisted keys, including keys for items the current fetch no longer returns (until pruning). Count keys present in `allItems`, or label it “restore all hidden keys.”

## Genuinely fixed (not re-raised)

Scope copy matches `involves:@me` and discloses the review-requested gap; one status owner; the second scheduler, sleeper and network gate are gone; the five slices are the right order; Keychain-only PAT with migration; unbounded hidden keys with derived counts; three phases plus derived staleness; routing and accessibility assigned; Alternative A2 present; truncation, cold start, snapshot no-overwrite and multi-window all addressed.

## Open Questions

1. Does a truncated success count as “complete” for replacement *and* pruning?
2. Who hydrates the persisted last-run summary — store `init` or workspace open?
3. Is the Refresh button a store call or a coordinator call, and does it move the next due time?
4. Is 400 the right cap for a user whose account has 89 items but whose organization has thousands?
5. (Carried) Do fine-grained PATs and SSO organizations need explicit support in v1?
