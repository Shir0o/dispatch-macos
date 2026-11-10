# Implementation Readiness Report — Final Stage 9

**Target:** `docs/designs/github_open_work.md` (DetailedRange 420–587, read with 1–419)

> **Post-audit patch applied.** After this audit, the detailed plan was patched for B1–B10 and the majors: the snapshot loader moved into Slice 3; `OpenWorkPresentation` and its tests are created in Slice 4; `OpenWorkIssuePayload`/`OpenWorkSearchResponse` are internal; the PAT fallback is removed in favor of Keychain-only plus “reconnect required”; `DetailPaneView` and `SettingsView` call sites are named; dispatch is split into payload and perform; the `hasStarted` guard is specified; `OpenWorkStatus` is `Sendable` only; the due-interval test moved to the store; `OpenWorkGroup`, `isFirstFetch`, `previousIndex`, the `KeychainStoring` seam, union seeding, the `refreshTask` identity check, the retry timeline, the draft-state removal, async signatures, and the normalize removal are specified. No further audit was run after that patch.

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-implementation-readiness` | completed |
| `egm-codebase-details` | completed |
| `egm-style` | completed |

## Verdict

The B1–B10 patch fixed the contract prose: `applySuccess`/`canPrune`, status-carried error identity, `clear()` keeping hides, the selection nil guard, environment injection, and the view-state tests. The plan still cannot be executed in order. Eight blockers remain; four are guaranteed compile breaks and two are contradictory contracts.

## Blocker

### B1. `SnapshotData.load(from:)` is used in Slice 3 but created in Slice 5 — Severity: Blocker

* **Reviewers:** all three
* **Affected Scope:** item 7 line 463; item 19 line 531; `TriageStore.swift:302,309`
* **Discrepancy:** `LegacyStateMigrator` reads through `SnapshotData.load(from:)`, added only in item 19. The snapshot path is private and `loadSnapshot` owns it. Slice 3 fails to compile, and missing/corrupt behavior is undefined.
* **Recommendation:** Move `SnapshotData.init(from:)`, `load(from:)` and a public snapshot-path helper into item 7. Define missing-file and corrupt-file behavior; leave quarantine to `loadSnapshot`. Item 19 consumes the loader.

### B2. `OpenWorkPresentation` is used in Slice 4 but created in Slice 5 — Severity: Blocker

* **Reviewers:** all three
* **Affected Scope:** item 13 line 497; item 23 line 548
* **Discrepancy:** `OpenWorkView` renders `OpenWorkPresentation`, but the type lands in Slice 5. The reducer input `(phase, isConfigured, itemCount, hiddenCount, error)` cannot produce the header, secondary line, truncation line, or “Retry at HH:MM.” `action` has no type or disabled state.
* **Recommendation:** Move item 23 into Slice 4 before item 13. Pass the full `OpenWorkStatus`, `visibleCount`, `hiddenCount`, `hasSummary` and `now`. Return `(label: String, action: OpenWorkAction, isEnabled: Bool)`, with `.openSettings`, `.updateToken`, `.retry(until:)`, `.refresh`, `.clearHidden`.

### B3. `mapOpenWorkItem` cannot be internal over private payload types — Severity: Blocker

* **Reviewers:** all three
* **Affected Scope:** item 1 line 429; item 2 line 434; `GitHubService.swift:405-434`
* **Discrepancy:** `OpenWorkIssuePayload`, `OpenWorkUserPayload` and `OpenWorkSearchResponse` are private. An internal mapper exposing a private parameter type is a compile error, and tests cannot build the input.
* **Recommendation:** Make the payload structs `internal` (or `package`) in item 2, or keep the mapper private and test only through decoded JSON. State the access level for each kept type.

### B4. The failed-migration fallback is unreachable and contradictory — Severity: Blocker

* **Reviewers:** all three
* **Affected Scope:** lines 286, 290, 293, 463, 526, 546
* **Discrepancy:** The provider is described as Keychain-only, then as two-source on failure. `isConfigured` comes from `hasGitHubPAT()`, which is false when the copy failed, so `refreshIfDue()` never runs and the fallback is dead. After item 18 removes `PreferencesStore.githubPAT`, a two-source provider cannot compile.
* **Recommendation:** Choose one: Keychain-only and “reconnect required” on failure, deleting the fallback and its test; or a two-source provider reading `UserDefaults.standard` directly, with `isConfigured = keychain || legacyDefaults` and a distinct reconnect state. Remove the other contract.

### B5. Slice 5 still references `TriageKind` in `DetailPaneView` — Severity: Blocker

* **Reviewers:** all three
* **Affected Scope:** item 20 line 536; `DetailPaneView.swift:202,366,397,426`; `TriageItem.swift:8-27`
* **Discrepancy:** Item 20 deletes the GitHub cases and both status enums but names only `TriageStreamView` helpers. `DetailPaneView` still switches on those types in `gitHubDetailView`, `statusPills`, `loadGitHubDetails` and `dispatchToAgent`.
* **Recommendation:** Name all four `DetailPaneView` functions and the `.gitHub` arm of `detailContent(for:)` in item 20; delete them in the same edit.

### B6. Settings still reads/writes `githubPAT` — Severity: Blocker

* **Reviewers:** readiness, codebase
* **Affected Scope:** item 10 line 478; `SettingsView.swift:140,406`; item 18 line 526
* **Discrepancy:** Item 10 removes the prefill only. The Clear PAT guard still reads `preferencesStore.githubPAT`, and validation still writes it. Item 18 removes the property, so Slice 5 fails to compile.
* **Recommendation:** Item 10 must remove every `preferencesStore.githubPAT` read/write, guard Clear PAT on `isGitHubConfigured`, and keep only the `githubUsername` assignment from validation.

### B7. The dispatch helper’s contract contradicts its signature — Severity: Blocker

* **Reviewers:** readiness, codebase
* **Affected Scope:** lines 280–282; `AgentDispatchService.swift:110-125`
* **Discrepancy:** `makePayload` only builds a payload, but the text says the helper copies or launches, handles `.none`, and checks terminal availability. No file or function owns those actions. `AgentDispatchService.dispatch` currently opens the terminal even for Clipboard Only. “Send title only” has no path because the helper refetches detail.
* **Recommendation:** Split `makePayload(item:detail:)` from `performDispatch(payload:preferences:)`. Change `AgentDispatchService.dispatch` so `.none` copies and returns without opening the terminal. Add `makeTitleOnlyPayload(item:)`. Name the alert owner and the `urlForApplication(withBundleIdentifier:)` availability check.

### B8. The setup guard can skip all wiring — Severity: Blocker

* **Reviewers:** readiness, codebase
* **Affected Scope:** item 7 line 463; `DispatchApp.swift:19,51,74,77`
* **Discrepancy:** The coordinator is constructed in `init`, so a `syncCoordinator == nil` guard is false on the first window and setup never assigns services, loads the snapshot, or starts polling.
* **Recommendation:** Use a separate `@State private var hasStarted = false` guard, or move service assignment and `start()` into `init`. State the exact condition.

### B9. `OpenWorkStatus` is declared Codable with a non-Codable error — Severity: Blocker

* **Reviewers:** codebase, style
* **Affected Scope:** item 1 line 429; `OpenWorkStatus`
* **Discrepancy:** `OpenWorkStatus` carries `error: OpenWorkFetchError?`, but only `OpenWorkLastRunSummary` needs persistence. Declaring both Codable fails to compile.
* **Recommendation:** `OpenWorkStatus: Sendable`; `OpenWorkLastRunSummary: Codable, Sendable`.

### B10. Coordinator tests need a clock/tick seam that no item creates — Severity: Blocker

* **Reviewers:** readiness, codebase
* **Affected Scope:** item 8 line 468; `SyncCoordinator.swift:208-223`
* **Discrepancy:** The test claims an injected clock and one refresh per due interval, but the coordinator has no clock or interval and sleeps 45 real seconds. The 900-second gate lives in the store.
* **Recommendation:** Move the due-interval assertion to `OpenWorkStoreTests`, which has `now`. Either inject a tick/interval into `SyncCoordinator` or test only that the loop calls the closure.

## Major Findings

* **M1. `OpenWorkGroup` is undefined.** Item 4 caches `groups`; no type or fields exist. Define `OpenWorkGroup { repository, items, visibleCount }`.
* **M2. `isFirstFetch` is impossible as written.** `hasFetchedThisLaunch` is set true at attempt start, so `applySuccess` cannot know it is the first fetch. Capture `isFirstFetch` before setting the flag, or compute `updatedCount` at attempt start.
* **M3. Selection fallback needs `previousIndex` captured before replacement.** State it explicitly in item 4.
* **M4. Migration tests have no Keychain seam.** Add a `KeychainStoring` protocol/closure and an injected snapshot URL so failure is deterministic and CI does not touch the login keychain.
* **M5. The hidden-key seed can replace newer hides.** State “union existing `dispatch.openWorkHiddenKeys` with migrated keys.”
* **M6. `refreshTask` can be clobbered by the old task’s `defer`.** Clear only when the handle is still the current task and generation.
* **M7. 403 “Retry at HH:MM” has no re-enable mechanism.** Add `retryAfter` and a one-minute timeline, or state it re-evaluates on redraw.
* **M8. `isDraft` has no source.** Search/issues does not return draft state reliably; drop it from `OpenWorkItemKind` for v1 or state it is always false.
* **M9. `noteWorkspaceOpened()`/`refreshIfDue()` signatures are unstated.** Declare them async and state that `.task` awaits them.
* **M10. `normalizeRepositories`/`normalizeOwners` have no removal owner.** Add their deletion to item 18 after the `PreferencesStore` edits, or remove them in item 6.
* **M11. `loadSnapshot` still writes `dismissedGitHubKeys`.** Item 19 names only `gitHubItems`; delete both assignments and write `nil`.
* **M12. Manual integration cannot produce “a URL-protocol 403.”** Move the 403 to tests or name a manual repro.
* **M13. The rollback check asserts dismissal keys that the new build deletes.** Narrow it to “Gmail items survive; GitHub hide history is not restored in the old build,” or dual-write for one release.
* **M14. `openSettings` is misattributed to `PreferencesStore`.** It is `@Environment(\.openSettings)`.

## Nit Findings

- `OpenWorkStatus` vs. store fields: reads/writes should go through `status`; state it once.
- Deduplication does not say which copy wins; specify first occurrence in page order.
- `AgentDispatchPayload` uses `localRepoPath`, not `localPath`.
- CUJ 3 still says `min(previousIndex, visibleCount - 1)` without the nil guard.
- Sidebar “successful load” predicate is undefined; use `status.phase == .ready || !allItems.isEmpty`.
- `isFirstLaunchEmptyState` drops trimming of `googleClientId`.
- `Cmd+Z` is described as routing, but no receiver exists; say “add a `Cmd+Z` receiver guarded by `canUndo`.”
- Row copy says “kind or state”; every item is open. Use “kind or draft state.”
- `OpenWorkView` says it reads `PreferencesStore` for `openSettings`; use the environment action.
- The warning gate still says “touched files”; SwiftPM cannot scope warnings by path.

## Slice Check

| Slice | Gate | Status | Blocking findings |
| --- | --- | --- | --- |
| 1 Models, fetch, fetch tests | build + fetch tests | Conditional | B3, B9 |
| 2 Store, store tests | build + store tests | Conditional | M1–M3, M6 |
| 3 Coordinator, root, migration, Settings | whole target builds | Fail | B1, B4, B6, B8, M4, M10 |
| 4 Views, routing, README | app builds | Fail | B2, B7, M14 |
| 5 Removals, migration/view tests | full suite | Fail | B4, B5, B6, M11 |

## Fixed and Not Re-raised

`applySuccess`/`canPrune`; status-carried error identity; `clear()` keeping hides and cancelling the task; selection nil guard; environment injection; first-open gating; `mapOpenWorkItem`; the view-state test file; quarantine instead of permanent save suppression; `updatedCount` copy; the dispatch builder name.
