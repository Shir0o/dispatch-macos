# Consolidated Review Report — GitHub Open Work (Post-Resolution)

**Target:** `docs/designs/github_open_work.md` (499 lines)
**Scope:** FeatureRange 1–346, DetailedRange 347–499
**Mode:** Consolidated report with all review rubrics
**Date:** 2026-11-09

## Reviewer Status

| Stage | Reviewer | Status |
| --- | --- | --- |
| 5. Initial Zoom Out | `egm-zoom-out` | completed |
| 6. Comprehension | `egm-comprehension` | completed |
| 7. Critic | `egm-design` | completed |
| 7. Critic | `egm-structural` | completed |
| 7. Critic | `egm-style` | completed |
| 8. Intermediate Zoom Out | `egm-zoom-out` | completed |
| 9. Implementation Readiness | `egm-implementation-readiness` | completed |
| 9. Implementation Readiness | `egm-codebase-details` | completed |
| 9. Implementation Readiness | `egm-style` | completed |

Individual reports: `zoom_out_report.md`, `comprehension_report.md`, `critic_report.md`, `intermediate_zoom_out_report.md`, `implementation_readiness_report.md`.

## Verdict

The previous revision fixed the structural objections: one query, one status owner, a coordinator timestamp, Keychain-only PAT direction, and a five-slice plan. The document is still not executable. The remaining eleven blockers are contracts and call-site gaps, not architecture. Three slice boundaries do not compile, the fetch cannot signal completeness, and the refresh clock and hidden-key migrations are still ambiguous.

The good news: the remaining work is enumerable. The bad news: it is not optional. A literal implementer will hit a build break in Slice 3 and lose hidden items on upgrade.

## Priority 0 — Blockers

### A1. Make the fetch contract complete and compilable

**Source:** S5 B1/B2; S6 #5; S7 B2/B3/B4; S8 B1/M5; S9 B2/B3
**Scope:** lines 168–182, 361; `GitHubService.swift:336-349,418-434`

Decide one contract and write it once:

* Own pagination in `fetchOpenWork`, or add a strict helper returning `(pages, stoppedAtCap, complete)`.
* Any non-2xx on any page throws. A 404 is not an empty success.
* Keep a search wrapper with `total_count`; do not delete `OpenWorkSearchResponse` without a replacement.
* Use the real helper signature including `context:`; state that pagination ends when no next link exists, not on a short page.
* Define `complete = !truncated && every page returned 2xx && pagination ended with no next link`.
* Set `truncated` only when `matchedCount > 400` or page four has a next link. At exactly 400, no truncation.

Replacement must happen on any success. Closed-item removal and hidden-key pruning happen only on a complete run.

### A2. Give the refresh clock one owner and one writer

**Source:** S5 B2; S6 #1; S7 B5; S8 B2/B3/M1; S9 B5
**Scope:** lines 184, 189–193, 249, 373, 385, 395

* Move `lastAttempt`, `hasOpened`, summary hydration and `refreshIfDue(force:)` into `OpenWorkStore`. The coordinator calls one method.
* Hydrate the persisted last-run summary in the store's `init`. The coordinator must not read it.
* Stamp `lastAttempt` before invoking the fetch, independent of success. A failed attempt must not retry every 45 seconds.
* Gate the first fetch on `!hasFetchedThisLaunch`, not on the persisted success time. After relaunch the list is empty, so it must fetch.
* Name the caller of the workspace-open method: `MainSplitView.onChange(of: activeWorkspace)` or `OpenWorkView.task`.
* Add `refreshOpenWorkIfDue()` to `handleSystemDidWake()`; the current wake path only restarts the loop and syncs Gmail.
* Store `refreshTask: Task<Void, Never>?`; every caller awaits it and no second request starts. Clear it in `defer`.
* Inject `now: @Sendable () -> Date` for tests.

Drop the “manual success resets the timestamp” sentence or route Refresh through a coordinator method that can observe the outcome.

### A3. Make every slice buildable

**Source:** S5 B1; S7 B6; S9 B1/B6/B7/B11
**Scope:** items 2, 3, 6–22; `MainSplitView.swift:35-40`; `SettingsView.swift:51,143`; `DispatchApp.swift:89-93`; `TriageStore.swift:157-159,318-319,332,334`; `DetailPaneView.swift:22,365-449`; `TriageStreamView.swift:198-224`

* Move `GitHubBackfillTests` deletion and the test updates into Slice 3 before removing the methods they call. `swift test` compiles every test file.
* Keep `OpenWorkUserPayload`; `OpenWorkIssuePayload` depends on it. Keep or replace the search wrapper.
* Enumerate every live call site by file and line: `preferencesStore.githubPAT` in `MainSplitView` and Settings, `setOnBackfillUpdated` and `setGitHubBackfill` in `DispatchApp`, `loadSnapshot`'s assignments, `mutateItem`, `star`, `archive`, `trash`, `streamTitle`, and `isFirstLaunchEmptyState`.
* Name the detail-pane rewrite: `body`, `statusPills`, `loadGitHubDetails`, `dispatchToAgent`, and the service source (`store.githubService` or a new `EnvironmentKey`; `@Environment(GitHubService.self)` does not compile).
* Name the stream cleanup: `reviewBadge`, `ciBadge`, and the GitHub row branches.
* Make `TriageStoreTests.makeTestItem` `.email`-only. Run `swift test --no-parallel` or `swift build --build-tests` at every slice gate; `--filter OpenWork` skips the snapshot tests.
* Replace `isFirstLaunchEmptyState`'s GitHub test with a Keychain configuration check, not `visibleCount == 0`. Otherwise onboarding overlays a legitimately empty or still-loading Open Work view.

### A4. Preserve the PAT and hidden state across the migration

**Source:** S6 #2/#6; S7 B7; S8 M2; S9 B8/B9
**Scope:** lines 204, 225, 373, 454, 459, 499; `TriageStore.swift:28-35,316`

* Copy `dispatch.githubPAT` to the Keychain, verify the write, then delete the defaults key. Do this in Slice 1 or 3, before the reader becomes Keychain-only.
* Seed `dispatch.openWorkHiddenKeys` from `SnapshotData.dismissedGitHubKeys` and the old defaults set, stripping `gh:` and lowercasing, before deleting either.
* Pick one migration site and one slice. `dispatch.dismissedGitHubIssueIDs` is currently deleted twice.
* Decode `gitHubItems` with `try?` or from a raw container. Optionality alone does not help if the element type still contains the old GitHub cases.
* Define `didLoadSnapshot` as “load attempted and failed”: true when no file exists (so a fresh install saves), true on decode failure, and suppress saves for the launch, not just the next one.
* Keep writing `gitHubItems: []`. “Stop writing new values” is ambiguous and breaks rollback.

### A5. Define construction, isolation and type conformance

**Source:** S6 #4; S7 B1/B8/M11/M12/M13; S9 B10/M9
**Scope:** lines 138–142, 181, 218–230, 249, 373, 390, 444

* Make `fetchAction` an initializer parameter. Create `GitHubService` before the store. State the pre-wiring behavior if an optional is used.
* Type the coordinator closure `@MainActor @Sendable () async -> Void`, or specify the explicit hop.
* Declare `OpenWorkFetchResult: Sendable`; `OpenWorkItemKind: Hashable`; `OpenWorkItem` keeps `Identifiable, Hashable, Sendable`.
* State that `fetchOpenWork` maps every `GitHubError` to `OpenWorkFetchError`, including `missingToken` and `invalidURL`.
* Name the dispatch rewrite: `Cmd+Shift+A` reads `openWorkStore.selectedItem` when GitHub is active, builds one payload from `repository`/`number`/`title`, and states whether the body is title-only or awaited detail. Define detail-fetch failure behavior.

### A6. Fix the header and state variants

**Source:** S7 B3; S7 M3/M4; S8 B2; S9 M2/M3
**Scope:** lines 39, 146–154, 211–215, 327

* Define the header by data availability: no items this session → “Not loaded this session · last refresh X ago · N matched”; items present → “N visible · H hidden · N matched · refreshed X ago”; running → a labelled Refresh state.
* Make error actions specific: 401 → “Update token” opens Settings; 403 → “Retry at HH:MM” disabled until reset; transport/5xx/decoding → Retry.
* Map every empty-state tuple to exact copy. A failed first refresh must not reuse “never refreshed” or “All Caught Up”.
* State that truncation copy is interpolated and counts fetched rows, not hidden rows.

### A7. Resolve the remaining hidden/undo and ordering defects

**Source:** S7 B1/B2; S7 M1/M5/M6/M7; S8 N2; S9 M5/M6
**Scope:** lines 42, 45, 54, 88, 199–202, 217, 328

* Sort groups by the newest item's `updatedAt` descending, tie-break by repository name. “Updated order” must exist globally, not only inside a section.
* Prune hidden keys only on a complete run; a truncated run leaves them untouched.
* Do not clear `lastHiddenKey` on refresh. Let the banner own dismissal, and add a hide → refresh → undo test.
* State the per-item restore limit or add per-key restore. “Restore all hidden (N)” after the banner is not per-item undo.
* Count `hiddenCount` from keys present in `allItems`, or label the action “Clear N hidden keys”.
* Key stability: a repository rename or transfer changes `owner/repo#number`. Use the numeric issue id if available, or state the limitation.
* Clear items, status, selection and the last-run summary when the PAT is removed; show a “GitHub not connected” state and stop due refreshes.

### A8. Fix the “why is this item here” and product-value claims

**Source:** S5 B3/M1/M7; S7 M9/M10; S7 style B1
**Scope:** lines 11–17, 45, 136, 306–308, 339

* Either add a relationship badge in v1 or make the omission a non-goal and rewrite the Problem and Success criterion so they do not claim a solved question.
* Add one sentence naming the job Open Work does better than `github.com/issues`: one window with Gmail, repository grouping, local hide, and `⌘⇧A` dispatch.

## Priority 1 — Majors

* **Counts and signal.** Add “H hidden” to the header. Decide whether an “updated since last view” marker is in scope or a non-goal; the Problem's “what did it bring in” is currently unanswered.
* **Compatibility.** Decide fine-grained/SSO support or state the limitation once. Reconcile “`repo` only” copy with fine-grained permissions.
* **Scope sentence owner.** The Overview says the view states it; the Views section puts it in Settings. Put it in the view header and keep Settings read-only.
* **Running state.** Goal 5 requires it; the header spec has no element. Specify the Refresh button's running label and disabled state.
* **Row dates.** Relative visually, absolute in the accessibility label; state both.
* **Active workspace.** List `activeWorkspace` among the properties `TriageStore` keeps, and state that views read it while stores do not read each other.
* **Terminology.** Standardize `selectedKey` vs `selection`, “live search” vs “live feed”, and “imported” vs “fetched”.
* **Removal wording.** Delete `ReviewStatus` and `CheckSuiteStatus` outright; remove `canonicalKey` as a property; do not call them “cases”.
* **Verification.** Remove account-specific numbers; turn the 403 into a URL-protocol test or name the launch hook; use the CI build command.

## Priority 2 — Nits

- `OpenWorkFetchResult` must be `Sendable`; `OpenWorkItemKind` must be `Hashable`.
- Item 6 files `GitHubService` removals under `SyncCoordinator.swift`; move them.
- `dispatch.dismissedGitHubIssueIDs` is deleted twice.
- Line 234 and line 459 disagree on whether `gitHubItems` is written.
- `hiddenCount` counts persisted keys, not visible-source keys.
- `selectNext()`/`selectPrevious()` end behavior is unstated.
- The shared URL-protocol stub lives in `SyncCoordinatorTests.swift`; name it to avoid a duplicate.
- Item 3's “exact encoded query” names no expected URL.
- Settings' “Clear PAT” path disappears with the connected check; name its replacement.
- Onboarding needs async Keychain state and an environment value.
- “Three components change role” is followed by four bullets.
- “One timestamp” is followed by two fields.
- The migration key's owner is undecided between Slice 2 and Slice 5.

## Traceability Matrix

| Action | Consolidated issue | Source findings |
| --- | --- | --- |
| A1 | Fetch completeness and compilation | S5 B1/B2, S6 #5, S7 B2/B3/B4, S8 B1/M5, S9 B2/B3 |
| A2 | Refresh clock, first fetch, single-flight | S5 B2, S6 #1, S7 B5, S8 B2/B3/M1, S9 B5 |
| A3 | Buildable slices and call sites | S5 B1, S7 B6, S9 B1/B6/B7/B11 |
| A4 | PAT and hidden-state migration | S6 #2/#6, S7 B7, S8 M2, S9 B8/B9 |
| A5 | Construction, isolation, dispatch | S6 #3/#4, S7 B1/B8/M11/M12/M13, S9 B10/M9 |
| A6 | Header and state variants | S7 B3/M3/M4, S8 B2, S9 M2/M3 |
| A7 | Hidden/undo and ordering | S7 B1/B2/M1/M5/M6/M7, S8 N2, S9 M5/M6 |
| A8 | Problem and product value | S5 B3/M1/M7, S7 M9/M10, S7 style B1 |
| P1 | Remaining majors | S7, S8, S9 majors |
| P2 | Nits | all stages |

## Recommended Path

1. Resolve A1–A8 in the design. These are contracts, not prose preferences. A1 and A2 change the Technical Plan; A3–A5 change the Detailed Plan; A6–A8 change the user-facing contract.
2. Re-run only Stage 9 after the revision. The full pipeline has now run twice; the feature-level findings are stable.
3. Treat the remaining majors as accepted trade-offs only if the document says so. Do not leave them implicit.

The one-audit cap in the review workflow is a process guard, not a technical limit. The document needs one more focused pass before implementation.
