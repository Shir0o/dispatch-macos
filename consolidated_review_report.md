# Consolidated Review Report — GitHub Open Work (Round 3)

**Target:** `docs/designs/github_open_work.md` (521 lines)
**Scope:** FeatureRange 1–365, DetailedRange 366–521
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

Individual reports: `zoom_out_report.md`, `comprehension_report.md`, `critic_report.md`, `intermediate_zoom_out_report.md`, `implementation_readiness_report.md`. Round-2 reports are archived in `review_archive/round2/`.

## Verdict

The architecture is right-sized. One query, one store, one list, one write action. The document is under-specified, not overbuilt. Four blockers keep recurring because the same invariant is restated in six places and fixed in one:

| Recurring blocker | Invariant never stated | Restated at |
| --- | --- | --- |
| Success versus complete | Success replaces and updates the summary; completeness permits pruning | 13, 37, 144, 179, 190, 221–224 |
| Migration order | No consumer reads a key before its producer writes it | 158, 212–213, 253, 411, 480 |
| Construction | The store exists before the first `body` pass | 105–115, 206, 411, 426, 456 |
| Error identity | The status carries the error, not its rendering | 78, 148–158, 191, 225–226 |

The remaining defects are real but local. Do not rebuild the design. Add one Contracts subsection, one state table, and fix four ordering passages.

## Priority 0 — Blockers

### A1. Separate success from completeness and fix truncation

**Source:** S5 B1; S6 #1; S7 B1; S8 B1; S9 M6
**Scope:** lines 13, 37, 144, 158, 178–190, 221–224

* One `applySuccess(result)`: always replace `allItems`, always update `lastSuccess`, `matchedCount` and `truncated`.
* Use `canPrune = complete` only to drop closed items and prune hidden keys.
* Rewrite lines 13 and 37 so they no longer say “replace only after a complete run.”
* Persist `fetchedCount` so the truncation line can render on cold start, or gate it on loaded items and omit the fetched count.
* Set `truncated` when `matchedCount > 400` or page four advertises a next link. Do not derive it from the deduplicated count.
* Remove “the visible list” as an operation; `visibleItems` is derived from `allItems`.

### A2. Gate the first fetch and name the trigger

**Source:** S5 M1; S6 #4; S7 B2; S8 B2; S9 B2
**Scope:** lines 37, 72, 187–199, 416; item 8

* Add `hasOpenedOpenWork` to the store. `refreshIfDue()` refreshes only when it is true, or after 15 minutes if already opened.
* `noteOpenWorkWorkspaceOpened()` sets it and triggers the first refresh.
* Name one caller: `OpenWorkView.task` or `MainSplitView.onChange`. Delete “or.”
* If launch-time fetching is intended instead, delete “first open” from Goal 3, CUJ 1 and item 8 and say the fetch starts at launch.
* Make the coordinator’s closure an init parameter or a named setter; remove the `gitHubService` dependency unconditionally.

### A3. Give the store an owner before `body`

**Source:** S5 B3; S6 #3; S7 B4; S8 B3; S9 B3
**Scope:** lines 206, 411; `DispatchApp.swift:7-21,42`

Pick one and state it in the Technical Plan:

* Build the root model in `DispatchApp.init`: `authService` as a `let`, then `gitHubService`, then `openWorkStore`, then inject it like `triageStore`.
* Or use `@State private var openWorkStore: OpenWorkStore?` plus a custom `EnvironmentKey` that unwraps in the four views.

No creation inside `setupServicesAndSync()`.

### A4. Order the migrations before the readers

**Source:** S5 B2; S6 #2/#6; S7 B3/B9; S8 B2/B7; S9 B4/B10
**Scope:** lines 204, 213, 240, 251–253, 411, 480

* Run one `migrateLegacyState()` before constructing `OpenWorkStore`: copy the PAT to the Keychain and verify, seed `dispatch.openWorkHiddenKeys` from `SnapshotData.dismissedGitHubKeys` and `dispatch.dismissedGitHubIssueIDs`, strip prefixes longest-first (`gh:issue:`, `gh:pr:`, `gh:`), lowercase, deduplicate, drop `gh:thread:` keys, then delete the old keys.
* Move the seed out of `TriageStore.loadSnapshot()` or guarantee `loadSnapshot()` runs first.
* Land the Settings/Onboarding Keychain checks in the same slice before deleting `dispatch.githubPAT`.
* State the order in one place: migrate → construct store → load snapshot → provider reads Keychain.
* If the Keychain write fails, do not switch the provider; report “reconnect required.” A retained defaults value is unreadable once the provider is Keychain-only.

### A5. Put error identity on the status and provide every recovery

**Source:** S5 B4; S6 #8; S7 B5/B7; S8 B4/B6; S9 B5
**Scope:** lines 78, 148–158, 191, 225–233

* `OpenWorkStatus` carries `error: OpenWorkFetchError?` or a `recovery` enum, not only `errorText`.
* One table row per case: 401 → Update token (opens Settings with the token field focused); 403 with reset → Retry at HH:MM, disabled until then; 403 without reset → Update token or retry; `notConfigured` → Connect; `notFound`/`decoding`/`server`/`transport` → Retry with specific copy.
* Settings keeps the token field and Validate & Save; the connected variant adds Clear PAT.
* `clear()` keeps hidden keys, cancels `refreshTask`, and discards results when `isConfigured` is false.

### A6. Define one state table, including loading and disconnected

**Source:** S6 #5; S7 B3/B8/B10; S8 B6; S9 M3/M7
**Scope:** lines 72, 188, 218, 221–226, 242

* Rows: loading, disconnected, never loaded, first-load failed, ready empty, ready with items, all hidden, stale with items.
* Each row has one header variant, empty-state copy, banner and CTA.
* Loading wins over empty. Error beats “not loaded.” A failed first load is not “stale.”
* The sidebar must not present `0 open items` as fact while unloaded or fully hidden; show no count or “—”.
* Name the async Keychain connected state and its `.task` in `MainSplitView`, Settings and Onboarding.

### A7. Make Slice 4 and Slice 5 build

**Source:** S7 B6/B7; S9 B1/B8
**Scope:** items 10–21; `TriageStreamView.swift:145-196`; `TriageStore.swift:130-145`; `TriageItem.swift:23-28`

* Keep the GitHub `TriageKind` cases in Slice 4 with neutral fallbacks, or move the enum cleanup into Slice 4 before the stream edits.
* Name `TriageStreamView.snippetText` and `badgesView`; deleting `reviewBadge`/`ciBadge` breaks the build.
* Name `TriageStore.selectedItem`’s `?? gitHubItems.first` and `activeItems`’ `.gitHub` branch as Gmail-only.
* Item 21’s old-snapshot fixture must be a committed raw JSON file; item 20 removes the cases needed to construct it.
* The coverage rows for Gmail unread belong in `TriageStoreTests`; the page-two 404 row belongs to the fetch error, not the list.

### A8. Pin the remaining types, files and builders

**Source:** S7 M5/M8/M9; S9 B7/B10/M5/M6/M8
**Scope:** items 2, 4, 12, 14, 18; `GitHubService.swift:418-535`; `AuthService.swift`

* Add `mapOpenWorkItem(_:) -> OpenWorkItem?` with the old `mapOpenWork` rules: skip nil repo URL or `html_url`; author `"ghost"`; fractional ISO-8601, plain ISO-8601, then `Date()`; key lowercased `repo#number`; kind from `pull_request`.
* Persist hidden keys as a string array; persist the last run as `Codable OpenWorkLastRunSummary { lastSuccess, matchedCount, truncated, fetchedCount }` JSON under `dispatch.openWorkLastRun`.
* Add `AuthService.swift` to the file list with `func hasGitHubPAT() -> Bool`.
* One `dispatch(openWorkItem:preloadedDetail:)` builder. The shortcut stays on `MainSplitView`, branches on `activeWorkspace`, and keeps the Gmail path. On detail failure, offer “Send title only / Cancel”; define the no-agent/no-terminal disabled state.
* Fix the truncation copy: “V shown of M matched (400-item cap; GitHub reports at most 1,000).”

### A9. Resolve the hide/restore promise

**Source:** S7 B1; S8 B5; S9 M1
**Scope:** lines 90, 202, 210–211, 229

Choose one:

* Drop per-item restore. Say “Undo within the banner; afterwards Restore all hidden,” and label the action “Clear all hidden keys (N).”
* Or add a Hidden items sheet listing key, title and hide time with a per-row restore.

Either way, keep `hiddenKeys` across Clear PAT, keep `lastHiddenKey` until the banner expires or a new hide replaces it, and add a hide → refresh → undo test.

### A10. Close the “what changed” gap

**Source:** S7 M6; S8 (drop)
**Scope:** lines 17, 45, 84

* Either add “N new/updated since last refresh” (a persisted last-viewed timestamp or a refresh marker), or declare it a non-goal and remove “what did it bring in” from the Problem. Do not leave the question answered by nothing.

## Priority 1 — Majors

* **Header overload.** Four counts, Refresh, a menu and a 110-character scope sentence do not fit a 280-point pane. Reduce to “Showing 400 of 1,000+ · 12 hidden” and move the scope to an info popover.
* **Scope copy is false for the edge cases.** Say “Open work involving @login that this token can read; review requests and subscriptions are not included.” Use it in the empty state too.
* **`e` changes meaning across workspaces.** Gmail archives; Open Work hides. Label it in a shortcut legend or use `h`. Show “Not available in Open Work” for `u`, `s`, `#` instead of swallowing.
* **Bulk actions have no confirmation.** Restore all and Clear PAT destroy curation. Confirm with counts; keep hides across Clear PAT.
* **`snapshotLoadFailed` has no exit.** Rename the corrupt file once (`snapshot.corrupt-<date>.json`), start clean, report it.
* **Migration sources and prefixes disagree.** Consolidate into one paragraph; longest prefix first; name the deleter; say when nil-writing begins.
* **Token-provider errors escape the mapping.** Map `AuthError` from `readKeychainValue` to `OpenWorkFetchError` at the service boundary.
* **Two launch flags can drift.** Keep one (`hasFetchedThisLaunch`) or derive it from `lastAttempt`.
* **Cold-start truncation cannot render.** Persist `fetchedCount` or gate the line on loaded items.
* **Undo liveness has no owner.** Add `undoDeadline`/`bannerTask`, `canUndo`, `dismissUndoBanner()`; test after expiry.
* **Header copy conflates last success and last attempt.** Say “last successful refresh” in every variant.
* **Focus jumps on background refresh.** Apply focus-follow only to user-initiated hides; keep it stable for background removals.

## Priority 2 — Nits

- “One component is new; four change role” is wrong; three change role.
- Risk text says relationship-reason items are excluded; they still appear.
- “live search” vs “live feed”; “session” vs “launch”; expand PAT/SSO/ETag.
- `ReviewStatus`/`CheckSuiteStatus` have no GitHub cases; say delete both enums.
- `complete` repeats the 2xx guarantee already enforced by the throw.
- The 400 cap copy is off by one: `truncated` is `matchedCount > 400`.
- Non-draft pull requests have no marker distinct from issues.
- Open Question 1 restates the settled non-goal.
- Account-specific 52/89 numbers appear in the alternatives.
- Item 9 says “seven-argument” but the tests have seven two-argument constructions.
- Item 3’s stub should name `MockURLProtocol` in `SyncCoordinatorTests.swift`.
- “Nearest item in flattened `groups`” needs `min(previousIndex, count - 1)`.
- The warning gate has no SwiftPM mechanism; use `swift build --build-tests 2>&1 | grep -q "warning:"` or drop it.
- Item 19/21 use `Type & Scope`; normalize.
- `deduplicated`, `repositoryName`, `newestFirst` become unused; list them.
- `normalizedTrackedRepositories`/`normalizedTrackedOwners` are orphaned; name them.
- `restoreAllHidden()` clears more keys than its label counts.
- `matchedCount`/`truncated` duplicate on result and status; hydrate once.

## Traceability Matrix

| Action | Consolidated issue | Source findings |
| --- | --- | --- |
| A1 | Success versus complete, truncation | S5 B1, S6 #1, S7 B1, S8 B1, S9 M6 |
| A2 | First-fetch gate and trigger | S5 M1, S6 #4, S7 B2, S8 B2, S9 B2 |
| A3 | Store construction | S5 B3, S6 #3, S7 B4, S8 B3, S9 B3 |
| A4 | Migration order and PAT | S5 B2, S6 #2/#6, S7 B3/B9, S8 B2/B7, S9 B4/B10 |
| A5 | Error identity and recovery | S5 B4, S6 #8, S7 B5/B7, S8 B4/B6, S9 B5 |
| A6 | State table and loading/disconnected | S6 #5, S7 B3/B8/B10, S8 B6, S9 M3/M7 |
| A7 | Slice 4/5 build integrity | S7 B6/B7, S9 B1/B8 |
| A8 | Types, files, mapping, dispatch | S7 M5/M8/M9, S9 B7/B10/M5/M6/M8 |
| A9 | Hide/restore promise | S7 B1, S8 B5, S9 M1 |
| A10 | “What changed” | S7 M6, S8 |
| P1 | Remaining majors | S7/S8/S9 majors |
| P2 | Nits | all stages |

## Recommended Path

Adopt the Stage 8 minimum patch rather than another full rewrite:

1. Add a **Contracts** subsection with five invariants: `applySuccess`/`canPrune`; migration-before-read; owner-before-`body`; status-carries-error; one refresh task and one dispatch builder.
2. Replace the scattered state copy with one state table.
3. Fix the four ordering/identity passages: lines 13/37, the store construction in item 7, the migration order in items 7/19, and the PAT delete order in items 7/12.
4. Drop per-item restore and “what did it bring in,” or implement them explicitly.
5. Leave the architecture, five slices and deletion list unchanged.

Then re-run only Stage 9. The full pipeline has run three times; further feature-level review will keep finding the same four contracts until they are written once.
