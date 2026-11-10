# Goldfish Annotated Review Report — Round 2

**Target:** `docs/designs/github_open_work.md` (full file)
**Findings source:** `consolidated_review_report.md` (A1–A8, P1, P2), with the five stage reports
**Status:** resolved

## Intake Notes

The first resolution log is preserved at `goldfish_review_report_round1.md`. This round covers the blockers and majors that survived or appeared in the second consolidated review. The design’s architecture is accepted; the proposed edits are contracts, call sites and copy.

## Prioritized Findings & AI Suggestions

### A1. The fetch cannot signal completeness and does not compile [`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 168–185, 361](docs/designs/github_open_work.md#L168-L185) (Fetch, Refresh, item 2); `GitHubService.swift:336-349,418-434`
* **Discrepancy Description:** The plan calls `requestAllPages(endpoint:maxPages:)` without the required `context:`, deletes the search wrapper that carries `total_count`, and reuses a helper that returns pages so far on a 404. A truncated run can prune hidden keys outside the 400-item window. At exactly 400 matches, the page-length rule falsely marks the set truncated.
* **Rationale:** This is the document’s central data-integrity contract. A partial 404 can empty the list and resurrect hidden work.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Own pagination inside `fetchOpenWork`; do not reuse the permissive helper. Keep the wrapper and make completeness explicit.
* **Proposed Edit:**
  * Location: Technical Plan Fetch and Refresh; item 2; item 3 tests; coverage matrix
  * Change: `fetchOpenWork` performs the page loop itself, sends the exact query, and throws `OpenWorkFetchError` on any non-2xx. Keep `OpenWorkUserPayload`; keep `OpenWorkSearchResponse` and add `total_count: Int`. Define `complete = !truncated && every page returned 2xx && pagination ended with no next link`. Set `truncated` only when `matchedCount > 400` or page four advertises a next link. Replace on any success; drop closed items and prune hidden keys only on `complete`. Update the test row to “page four full and `matchedCount > 400`.”

### A2. The refresh clock and first fetch still have no single owner [`egm-zoom-out`, `egm-comprehension`, `egm-structural`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 184, 189–193, 249, 373, 385, 395](docs/designs/github_open_work.md#L184-L193) (Refresh, Concurrency, items 4 and 6)
* **Discrepancy Description:** `lastOpenWorkAttempt` is stamped on success only, so a revoked PAT retries every 45 seconds. “A manual success resets it” cannot be observed by a coordinator that never reads store state. `noteOpenWorkWorkspaceOpened()` has no caller. A five-minute-old persisted summary suppresses the first fetch. “Await the in-flight call” has no task. Wake does not call the due check.
* **Rationale:** The refresh behavior is the feature’s main promise; it must be one deterministic contract.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Move the clock and hydration into the store. The coordinator becomes a trigger, not a second owner.
* **Proposed Edit:**
  * Location: Component map; Refresh and failure; Store behavior; Concurrency; items 4, 6, 7, 8
  * Change: `OpenWorkStore` owns `lastAttempt`, `hasFetchedThisLaunch`, `refreshTask: Task<Void, Never>?`, summary hydration in `init`, and `refreshIfDue(force:) async`. Stamp `lastAttempt` before the fetch, independent of outcome. Gate the first launch fetch on `!hasFetchedThisLaunch`, not the persisted success time. The coordinator’s 45-second loop and wake handler call `refreshIfDue()`; the workspace-open hook calls `refreshIfDue(force: false)`. `refresh()` awaits `refreshTask` when present and otherwise creates one, clearing it in `defer`. Inject `now: @Sendable () -> Date`. Name the caller of the workspace-open hook (`MainSplitView.onChange(of: activeWorkspace)` or `OpenWorkView.task`). Delete the manual-reset sentence.

### A3. Three slice boundaries still do not build [`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 347–471](docs/designs/github_open_work.md#L347-L471) (Detailed Plan); `GitHubBackfillTests.swift`; `MainSplitView.swift:35-40`; `SettingsView.swift:51,143`; `DispatchApp.swift:89-93`; `TriageStore.swift:157-159,318-319,332,334`; `DetailPaneView.swift:22,365-449`; `TriageStreamView.swift:198-224`
* **Discrepancy Description:** Slice 3 removes methods `GitHubBackfillTests` still calls. Slice 5 leaves live references to `githubPAT`, `setOnBackfillUpdated`, `setGitHubBackfill`, and the snapshot load/save fields. `DetailPaneView` and `TriageStreamView` still reference deleted `TriageKind` cases and status enums. `@Environment(GitHubService.self)` does not compile.
* **Rationale:** The plan’s own rule says no slice leaves a removed symbol with a caller.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Move the test edits with the removals and enumerate every call site by line. Use `store.githubService` or add an `EnvironmentKey`.
* **Proposed Edit:**
  * Location: Slices 3–5, items 2–22
  * Change: Move `GitHubBackfillTests` deletion and the `SyncCoordinatorTests` updates into Slice 3 before item 6. Keep `OpenWorkUserPayload` and the search wrapper. Add to the named items: `MainSplitView.swift:37`, `SettingsView.swift:51,143`, `DispatchApp.swift:89-93`, `TriageStore.swift:157-159,318-319,332,334`, `DetailPaneView`’s `body`, `statusPills`, `loadGitHubDetails`, `dispatchToAgent`, and `TriageStreamView`’s `reviewBadge`/`ciBadge`. Replace `isFirstLaunchEmptyState`’s GitHub test with a Keychain configuration check, not `visibleCount == 0`. Make `TriageStoreTests.makeTestItem` `.email`-only. Run `swift test --no-parallel` at every gate.

### A4. The PAT and hidden-state migrations discard data [`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 204, 225, 373, 454, 459, 499](docs/designs/github_open_work.md#L204-L225); `TriageStore.swift:28-35,316`
* **Discrepancy Description:** The defaults PAT is deleted without copying it to the Keychain, while the reader becomes Keychain-only in Slice 3. `dispatch.dismissedGitHubIssueIDs` is deleted twice. The live prior hidden set is `SnapshotData.dismissedGitHubKeys`, which is ignored. `decodeIfPresent([TriageItem])` still throws on old GitHub kinds. `didLoadSnapshot` as written suppresses the first save on a fresh install and only one save after corruption.
* **Rationale:** Existing users would lose their PAT and every hidden item on upgrade; the snapshot claim is false.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Migrate first, then delete. Use one flag with a clear polarity.
* **Proposed Edit:**
  * Location: PAT storage; Removals and compatibility; items 4, 18, 19
  * Change: Copy `dispatch.githubPAT` to the Keychain, verify the write, then delete, in Slice 1 or 3. Seed `dispatch.openWorkHiddenKeys` from `SnapshotData.dismissedGitHubKeys` and the old defaults set, stripping `gh:` and lowercasing, before deleting either. Pick one migration site. Decode `gitHubItems` with `try?` or a raw container. Replace `didLoadSnapshot` with `snapshotLoadFailed`, false by default and true only on a decode error; suppress saves for the launch when true. Keep writing `gitHubItems: []`. Test no-file, corrupt-file and old-snapshot cases.

### A5. Construction, isolation, dispatch and type conformance are undefined [`egm-comprehension`, `egm-structural`, `egm-implementation-readiness`] — Severity: High

* **Affected Scope:** [lines 138–142, 181, 218–230, 249, 373, 390, 444](docs/designs/github_open_work.md#L138-L142)
* **Discrepancy Description:** `fetchAction` is a non-optional held dependency wired after construction; Settings can call `refresh()` before wiring. The coordinator closure is nonisolated while `refresh` is `@MainActor`. `OpenWorkFetchResult` is not `Sendable`; `OpenWorkItemKind` is not `Hashable`. `missingToken`/`invalidURL` have no error case. The `⌘⇧A` body source is undefined; one path sends the title, the other the cached detail.
* **Rationale:** These are compile and behaviour gaps, not preferences.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Pin one initializer, one hop, one mapping and one payload builder.
* **Proposed Edit:**
  * Location: Data model; Concurrency; items 4, 7, 10, 12
  * Change: `OpenWorkStore.init(fetchAction:defaults:now:)`. Create `GitHubService` before the store. Type the coordinator refresh closure `@MainActor @Sendable () async -> Void`. Declare `OpenWorkFetchResult: Sendable`, `OpenWorkItemKind: Hashable`. Map `GitHubError` inside `fetchOpenWork`, including `missingToken` → `unauthorized` (or `.notConfigured`) and `invalidURL` → `.transport`. `⌘⇧A` fetches detail and builds one payload; on failure it sends title-only and says so. Detail-fetch failures render inline.

### A6. Header and empty-state variants are undefined [`egm-design`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 39, 146–154, 211–215, 327](docs/designs/github_open_work.md#L211-L215) (Goals, status, Views, Risks)
* **Discrepancy Description:** A failed first refresh matches both “never refreshed” and “first refresh failed.” A persisted matched count can sit above an empty list. The header has no running element despite Goal 5. Error actions are Retry-only, which cannot fix a revoked token. Truncation copy counts hidden rows as shown.
* **Rationale:** The view exists to stop misleading states; these are the states users see first.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Define one predicate table and one header format.
* **Proposed Edit:**
  * Location: Goal 5; Views; Risks
  * Change: Header variants: no items this session → “Not loaded this session · last refresh X ago · N matched”; items → “N visible · H hidden · N matched · refreshed X ago”; running → the Refresh button label and disabled state. Empty states: never refreshed, first refresh failed, ready and empty, all hidden. Errors: 401 → “Update token” (Settings); 403 → “Retry at HH:MM” disabled until reset; transport/5xx/decoding → Retry. Truncation: “X fetched · Y matched (capped)” with interpolated values.

### A7. Hidden work, undo and list ordering still break their own promises [`egm-design`, `egm-structural`] — Severity: High

* **Affected Scope:** [lines 42, 45, 54, 88, 199–202, 217, 328](docs/designs/github_open_work.md#L199-L202)
* **Discrepancy Description:** Groups sort by repository name, so “updated order” is only local. A successful refresh clears `lastHiddenKey` while the undo banner may still be visible. Only bulk restore exists after the banner. `hiddenCount` counts persisted keys, not visible-source keys. Key stability fails on repository rename/transfer. Removing the PAT leaves a populated workspace.
* **Rationale:** Hiding is the only write action; its inverse and ordering must be reliable.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Sort groups by newest item; keep the undo target until the banner ends; add per-item restore; clear the workspace on disconnect.
* **Proposed Edit:**
  * Location: Store behavior; Views; PAT storage; Risks
  * Change: Sort groups by newest `updatedAt`, tie-break by name. Prune hidden keys only on a complete run. Keep `lastHiddenKey` until the banner expires or a new hide replaces it; bind `Cmd+Z`. Add per-item restore and keep “Restore all” as fallback. Count `hiddenCount` from `allItems`. State the rename limitation or key on the numeric issue id. On PAT removal, clear items, status, selection and last-run summary; show “GitHub not connected” and stop due refreshes.

### A8. The Problem and success criterion claim a question the design excludes [`egm-design`, `egm-style`, `egm-zoom-out`] — Severity: High

* **Affected Scope:** [lines 11–17, 45, 136, 306–308, 339](docs/designs/github_open_work.md#L11-L45)
* **Discrepancy Description:** “Why is this item here” is in the Problem, but relationship data is deferred and the non-goals never say so. The success wording quietly changes the question. The Overview never names the job Open Work does better than `github.com/issues`.
* **Rationale:** A design that claims an unsolved question loses credibility and misdirects the implementer.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Either show relationship badges or state the omission. Name the product value once.
* **Proposed Edit:**
  * Location: Overview; The Problem; Success; Non-Goals; Future Improvements
  * Change: Rewrite the third question as “why is the list stale or truncated.” Move per-item relationship reasons to a non-goal and future improvement. Add one sentence: “Open Work keeps the user's GitHub work in the same window as Gmail, grouped by repository, with local hide and `⌘⇧A` dispatch.” Remove the claim that the query explains why each item matched.

### P1. Remaining majors [`egm-*`] — Severity: Medium

* **Affected Scope:** various
* **Discrepancy Description:** Counts and “what changed” signal; fine-grained/SSO compatibility; scope-sentence owner; running state; row date roles; `activeWorkspace` retention; terminology; removal wording; verification commands.
* **Rationale:** Each is a user-facing or implementer-facing ambiguity that survives the blocker fixes.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Apply the same one-owner/one-term rule used above.
* **Proposed Edit:**
  * Location: Views, NFR, Removals, Verification, item 15
  * Change: Add “H hidden” to the header and decide whether “updated since last view” is in or out. Document fine-grained/SSO as a v1 limitation once. Put the scope sentence in the view header; keep Settings read-only. Specify the running Refresh label. State relative dates visually and absolute dates in accessibility labels. List `activeWorkspace` among the properties `TriageStore` retains. Standardize `selectedKey`, “live search,” and “fetched.” Delete `ReviewStatus` and `CheckSuiteStatus` outright; call `canonicalKey` a property. Remove account-specific numbers and make the 403 a unit test or name a launch hook.

### P2. Nits [`egm-*`] — Severity: Low

* **Affected Scope:** various
* **Discrepancy Description:** `OpenWorkFetchResult`/`OpenWorkItemKind` conformances; item 6 mis-files service removals; duplicate migration key; “stop writing” vs “save `[]`”; hidden count; selection end behavior; shared URL-protocol stub location; exact query URL; Clear PAT path; Onboarding async state; “three components”/four bullets; “one timestamp”/two fields; migration owner.
* **Rationale:** They do not block implementation but cause avoidable churn.
* **AI Suggestion:** PROPOSE FIX for the factual contradictions; DECLINE for cosmetic structure.
* **Justification:** Fix what an implementer would act on; leave formatting preferences.
* **Proposed Edit:**
  * Location: items 2, 3, 4, 6, 15, 18; data model; verification
  * Change: Add the conformances; move service removals to item 2; assign the legacy key deletion to one item; use “save `gitHubItems: []`”; count hidden keys from `allItems`; specify selection stop behavior; name the shared mock; state the literal query URL; name the Clear PAT replacement; add Onboarding’s async Keychain state; fix “one new component; three change role”; fix “one timestamp” to list both fields; choose one migration owner.
  * **DECLINE:** promoting Additional Resources/Future Improvements to H2, and any pure formatting preference.
  * **ESCALATE:** Whether fine-grained PATs and SSO organizations must be supported in v1. This is an audience decision, not a document or code fact.

## Resolution Summary

| Category | Count |
| --- | --- |
| Accepted and applied | 8 blockers, 9 majors, 12 factual nits |
| Contested | 0 |
| Escalated | 1 (fine-grained/SSO support) |
| Declined | 2 (H2 promotion, cosmetic formatting) |
| Remaining unaddressed | 1 (the escalated question) |

### Applied changes

* `fetchOpenWork` owns its pagination, throws on any non-2xx, returns `complete`, keeps the search wrapper with `total_count`, and never treats 404 as empty success. Truncation is `matchedCount > 400` or a next link after page four.
* The store owns `lastAttempt`, `hasFetchedThisLaunch`, summary hydration, the refresh task and `refreshIfDue()`. Attempts are stamped at the start, so failures are throttled. The first fetch ignores the persisted timestamp.
* The five slices are reordered and enumerated: Slice 3 deletes `GitHubBackfillTests` before removing service methods and updates the coordinator tests; Slice 5 updates Settings/Onboarding before removing the UserDefaults PAT; tests run with the full suite.
* The PAT is copied to the Keychain, verified, then deleted. Hidden keys are seeded from `SnapshotData.dismissedGitHubKeys` and the old defaults set with prefixes stripped. `gitHubItems` decodes with `try?`; `snapshotLoadFailed` protects a corrupt file.
* `fetchAction` is an initializer parameter; the coordinator closure is `@MainActor @Sendable`; `OpenWorkFetchResult` is `Sendable`; `OpenWorkItemKind` is `Hashable`; `GitHubError` maps to `OpenWorkFetchError`.
* The header has three variants, the empty states have exact copy, and errors have action-specific recovery. Hidden work sorts by newest, prunes only on complete runs, survives refresh, and supports per-item restore plus `Cmd+Z`.
* The Problem no longer claims relationship reasons; the success criterion now matches the data model. The Overview states the product value.
* The detail pane uses `store.githubService`; `⌘⇧A` fetches detail and falls back to title-only with a toast. The service is no longer stored on `OpenWorkStore`.
* Verification uses the full test suite and a coverage matrix; the 403 case is a unit test.

The design document at `docs/designs/github_open_work.md` has been updated. No source files were changed.
