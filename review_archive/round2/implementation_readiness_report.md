# Implementation Readiness Report — DetailedRange (Post-Resolution)

**Target:** `docs/designs/github_open_work.md` (lines 347–499)

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-implementation-readiness` | completed |
| `egm-codebase-details` | completed |
| `egm-style` | completed |

## Verdict

Not executable as written. The slice order is right and the architecture is stable, but the plan still leaves the fetch contract, the refresh clock, the hidden-key migration and several call sites undecided. Three slice boundaries do not compile, and several verification rows cannot be satisfied by the code the plan describes.

## Blocker

### B1. Slice 3 cannot compile the test target — Severity: Blocker

* **Reviewers:** readiness, codebase, style
* **Affected Scope:** item 6 line 385; item 22 line 471; `Tests/DispatchAppTests/GitHubBackfillTests.swift:87,142,201,243,299-385`
* **Discrepancy:** Item 6 removes `fetchOpenIssuesAndPullRequests`, `decodeOpenWork`, `decodeSearchOpenWork`, `mapOpenWork`, `OpenWorkSearchResponse` and `OpenWorkUserPayload` in Slice 3. `GitHubBackfillTests` still calls them and `setGitHubBackfill`, and it is deleted only in Slice 5. `swift test` compiles every test file, so Slice 3 fails its own gate. Removing `OpenWorkUserPayload` also breaks `OpenWorkIssuePayload`, which stores `user` and `assignees` of that type.
* **Recommendation:** Move the `GitHubBackfillTests` deletion and the test updates into Slice 3 before item 6, keep `OpenWorkUserPayload`, and keep or extend a search wrapper. Alternatively, move all `GitHubService` removals to Slice 5.

### B2. The fetch contract does not compile and treats 404 as success — Severity: Blocker

* **Reviewers:** readiness, codebase, style
* **Affected Scope:** lines 168, 361; `GitHubService.swift:336-349`
* **Discrepancy:** `requestAllPages` is private, requires `context:`, and returns the pages collected so far on a 404. The plan calls it without `context:`. A page-one 404 becomes an empty successful result; a page-two 404 becomes a partial result that replaces the list and prunes hidden keys. `truncated` cannot distinguish “stopped at the cap” from “stopped because of a failure”.
* **Recommendation:** Own pagination in `fetchOpenWork` or add a strict helper returning `(pages, stoppedAtCap, complete)`. Any non-2xx on any page throws. State the exact call including `context:`. A short page alone does not end pagination; the absence of a next link does.

### B3. `total_count` has no carrier — Severity: Blocker

* **Reviewers:** readiness, codebase, style
* **Affected Scope:** lines 169, 231, 361, 385; `GitHubService.swift:432-434`
* **Discrepancy:** The plan deletes `OpenWorkSearchResponse`, the only search wrapper, while requiring `total_count`. `OpenWorkIssuePayload` is a single issue record. No type decodes the wrapper.
* **Recommendation:** Keep `OpenWorkSearchResponse` and add `total_count: Int`, naming that edit in item 2. State the result when page one succeeds with zero items.

### B4. “Complete” is undefined, and the truncation rule contradicts its test — Severity: Blocker

* **Reviewers:** readiness, codebase, style
* **Affected Scope:** lines 171, 182, 202, 328, 373, 489–491
* **Discrepancy:** Pruning is gated on “success”, not `truncated`. A 400-item capped run prunes hidden keys outside the window, which resurrect later. At exactly 400 matches, page four returns 100 items and the plan sets `truncated` even though the set is complete. `hiddenKeys` is called unbounded at line 202 and bounded by pruning at line 182.
* **Recommendation:** Define once: `complete = !truncated && every page returned 2xx && pagination ended with no next link`. Replace on any success; drop closed items and prune hidden keys only when `complete`. Drop the page-length clause; set `truncated` only when `matchedCount > 400` or a next link exists after page four. Rewrite the test row accordingly.

### B5. The refresh clock has no writer and the first fetch has no caller — Severity: Blocker

* **Reviewers:** readiness, codebase, style, zoom-out
* **Affected Scope:** lines 184, 189–193, 249, 373, 385, 395, 492–493; `SyncCoordinator.swift:360-368`
* **Discrepancy:** `lastOpenWorkAttempt` is stamped on success only, so a revoked PAT retries every 45 seconds. “A manual success resets it” cannot be observed by a coordinator that never reads store state. `noteOpenWorkWorkspaceOpened()` has no caller. A persisted summary younger than 15 minutes suppresses the first fetch of the launch, leaving an empty list under a fresh timestamp. “Await the in-flight call” has no task handle. Wake does not call the due check.
* **Recommendation:** Move `lastAttempt`, `hasOpened`, summary hydration and `refreshIfDue(force:)` into the store; the coordinator calls one method and adds `refreshOpenWorkIfDue()` to wake. Stamp `lastAttempt` before invoking the fetch, independent of outcome. Gate the first fetch on `!hasFetchedThisLaunch`, not the persisted success time. Store `refreshTask: Task<Void, Never>?` and await it. Inject `now: @Sendable () -> Date`.

### B6. The removal lists still leave live callers — Severity: Blocker

* **Reviewers:** readiness, codebase, style, zoom-out
* **Affected Scope:** `MainSplitView.swift:37`; `SettingsView.swift:51,143`; `DispatchApp.swift:89-93`; `TriageStore.swift:157-159,318-319,332,334`; items 7, 10, 16, 18, 19
* **Discrepancy:** The plan does not name `preferencesStore.githubPAT` in `MainSplitView`, Settings' prefill and clear, `coordinator.setOnBackfillUpdated`, the `setGitHubBackfill` call, or `loadSnapshot`'s assignments to `gitHubItems` and `dismissedGitHubKeys`. Removing the properties or the PAT makes each a compile error.
* **Recommendation:** Add each call site to the item that removes its dependency, by file and line. Replace the connected check with a Keychain read and the loader assignments with explicit discarded values.

### B7. The detail pane and stream still reference deleted types — Severity: Blocker

* **Reviewers:** readiness, codebase, style
* **Affected Scope:** item 12 line 419; item 14 line 429; item 20 line 464; `DetailPaneView.swift:22,365-449`; `TriageStreamView.swift:198-224`
* **Discrepancy:** Item 12 never restructures `body` (which gates on `store.selectedItem`), `statusPills`, `loadGitHubDetails` or `dispatchToAgent`. Item 14 does not name `reviewBadge`/`ciBadge`, which use the deleted status enums. `GitHubService` is a non-`Observable` final class, so `@Environment(GitHubService.self)` will not compile; use `store.githubService` or add an `EnvironmentKey`.
* **Recommendation:** Enumerate every function to replace or delete, and name the service source. Specify the top-level workspace switch.

### B8. The PAT and hidden-state migrations discard data — Severity: Blocker

* **Reviewers:** readiness, codebase, style, zoom-out
* **Affected Scope:** lines 204, 225, 373, 454, 459, 499
* **Discrepancy:** The defaults PAT is deleted without copying it to the Keychain, while the reader becomes Keychain-only in Slice 3. `dispatch.dismissedGitHubIssueIDs` is deleted in two places. The live prior hidden set is `SnapshotData.dismissedGitHubKeys`, which is decoded as optional and then ignored. Old keys use `gh:repo#num`; new keys use lowercased `repo#num`.
* **Recommendation:** Copy the PAT to the Keychain, verify the write, then delete. Seed `dispatch.openWorkHiddenKeys` from both the snapshot set and the defaults set, stripping `gh:` and lowercasing, before deleting either. Pick one slice and one migration site. Test with a real old snapshot.

### B9. The snapshot decoder still fails on old GitHub items — Severity: Blocker

* **Reviewers:** codebase, style
* **Affected Scope:** item 19 line 459; item 20 line 464; `TriageStore.swift:28-35,316`; `TriageItem.swift:23-28`
* **Discrepancy:** Treating `gitHubItems` as optional does not help if the element type still contains `.gitHubIssue`/`.gitHubPullRequest`; `decodeIfPresent([TriageItem].self, ...)` throws on the old payloads. The whole snapshot decode fails, so Gmail items are lost.
* **Recommendation:** Decode `gitHubItems` with `try?` or from a raw container and ignore failure. Keep writing `[]`. Test with real old JSON. Define `didLoadSnapshot` as “load attempted and failed”: true when no file exists (so a fresh install still saves), true on decode failure, and suppress saves for the launch, not just the next save.

### B10. `fetchAction` and the coordinator closure have no construction or isolation contract — Severity: Blocker

* **Reviewers:** readiness, codebase, style
* **Affected Scope:** lines 181, 249, 373, 390, 444
* **Discrepancy:** The store “holds” a non-optional `fetchAction`, while the composition root wires it after construction. Settings can call `refresh()` before wiring. The coordinator closure is declared `@Sendable () async -> Void`, but `openWorkStore.refresh` is `@MainActor`; under Swift 6 strict concurrency that assignment does not type-check.
* **Recommendation:** Make `fetchAction` an initializer parameter, create `GitHubService` before the store, and type the coordinator closure `@MainActor @Sendable () async -> Void` or specify the explicit main-actor hop.

### B11. The Slice 5 order and verification command are not buildable — Severity: Blocker

* **Reviewers:** codebase, style
* **Affected Scope:** item 19 line 459; item 20 line 464; items 21–22; line 479
* **Discrepancy:** Items 18–20 remove symbols before items 21–22 edit or delete tests. `TriageStoreTests.makeTestItem` still falls back to `.gitHubIssue`; `GitHubBackfillTests` still calls the normalizers. `swift test --filter OpenWork` excludes `TriageStoreTests` and `SyncCoordinatorTests`, so the snapshot tests are not run at the Slice 5 checkpoint. `swift build` does not compile tests.
* **Recommendation:** Edit or delete the tests in the same commit as the removals, make the test helper `.email`-only, and run `swift test --no-parallel` (or `swift build --build-tests`) at every slice gate.

## Major Findings

* **M1. Dispatch body is undefined.** `MainSplitView` sends `body: item.title`; `DetailPaneView` sends the cached detail. State whether `Cmd+Shift+A` sends title-only or awaits detail, and what happens before detail loads. Use one payload builder.
* **M2. Header and empty-state variants are undefined.** A failed first refresh matches both “never refreshed” and “first refresh failed”. Specify an ordered predicate table with exact copy and the header for each state.
* **M3. Error recovery is not error-specific.** 401 needs “Update token”; 403 needs a disabled Retry until reset; transport/5xx/decoding need Retry. `missingToken` and `invalidURL` have no `OpenWorkFetchError` case.
* **M4. Detail-fetch failures are outside the contract.** State whether a 401/403 on `fetchIssueDetails` is shown inline, retried, or leaves the list untouched.
* **M5. The Undo banner can outlive its key.** A successful refresh clears `lastHiddenKey` while the banner is visible. Let the banner own dismissal; add a hide → refresh → undo test.
* **M6. Unused symbols and dependency changes are unlisted.** Removing the fan-out leaves `deduplicated`, `repositoryName`, `newestFirst` and the coordinator's `gitHubService` unused. Removing that dependency changes `DispatchApp` and seven test constructors.
* **M7. `isFirstLaunchEmptyState` still overlays onboarding.** It reads `preferencesStore.githubPAT` and `visibleCount == 0`; a legitimately empty or still-loading Open Work view is hidden. Gate on Keychain configuration, not item count.
* **M8. `OpenWorkItem` mapping and `total_count` handling are unspecified.** State where `OpenWorkIssuePayload → OpenWorkItem` lives and what happens on nil `user.login` or an unparsable `html_url`.
* **M9. `OpenWorkFetchResult` is not `Sendable`; `OpenWorkItemKind` needs `Hashable`.** Required by the fetch boundary and the item conformance.
* **M10. Verification is not runnable.** Remove the maintainer-account numbers, make the 403 case a unit test or name a launch hook, and align build commands with CI.

## Nit Findings

- Item 6 files `GitHubService` removals under `SyncCoordinator.swift`; move them to item 2.
- `dispatch.dismissedGitHubIssueIDs` is deleted twice.
- Line 234 says “stop writing new values”; line 459 says “Save `gitHubItems: []`”. Pick one.
- `hiddenCount` / “Restore all hidden (N)” counts persisted keys, not keys in `allItems`.
- `lastHiddenKey` is cleared by a successful refresh.
- `selectNext()` / `selectPrevious()` have unstated end behavior.
- The shared URL-protocol stub lives in `SyncCoordinatorTests.swift`; name it to prevent a duplicate.
- Item 3’s “exact encoded query” names no expected URL; state the literal.
- `SettingsView` “Clear PAT” disappears with the connected check; name its replacement.
- `OnboardingView`’s `isConnected` needs new async state and an environment value.

## Slice Check

| Slice | Builds and tests as specified? | Blocking defect |
| --- | --- | --- |
| 1 Models/fetch | Only after B2/B3 | helper signature, `total_count` carrier |
| 2 Store | Only after B4/B10 | prune gate, fetch wiring |
| 3 Coordinator | No | B1 test target, B5 clock, B6 call sites, B10 isolation |
| 4 Views | Yes against the old model | B7 detail routing, M7 onboarding |
| 5 Removals | No | B6, B7, B8, B9, B11 |
