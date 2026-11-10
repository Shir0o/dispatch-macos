# Goldfish Annotated Review Report

**Target:** `docs/designs/github_open_work.md` (full file, lines 1–453)
**Findings source:** `consolidated_review_report.md` plus the five stage reports
**Status:** resolved

## Intake Notes

The consolidated report contains 23 action items (A1–A23). A1–A10 are blockers, A11–A22 are majors, and A23 collects the remaining nits. Each item below is categorized as CONTEST, ESCALATE, PROPOSE FIX or DECLINE. Proposed edits are structural: they name the section and the replacement rule rather than reproducing the full new text.

## Prioritized Findings & AI Suggestions

### A1. Scope does not match the query [`egm-design`, `egm-structural`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 11, 35, 51, 173, 444](docs/designs/github_open_work.md#L11-L51) (Problem, Goals, Non-Goals, Fetch, README item)
* **Discrepancy Description:** The document says `involves:@me` covers subscribed work and that the current backfill imports “involving” work. GitHub defines `involves:` as author, assignee, mentions and commenter. Subscribed is not included. The current default `/issues?filter=all` means all issues the user can see, which is broader.
* **Rationale:** The design would silently narrow scope while claiming parity, which is the failure mode it exists to remove.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** The reviewer is right on both API semantics. The user chose involvement scope, not all-visible and not a second subscription query. The honest fix is to state the four relationships and record the loss. The request to add review-requested work is contested separately: it is an explicit user decision and a non-goal, but the copy must state it.
* **Proposed Edit:**
  * Location: Overview line 11; Goal 1 line 35; Non-Goal line 51; Fetch line 173; README item line 444
  * Change: Replace “authored, assigned, mentioned, commented on, or subscribed” with “authored, assigned, mentioned, or commented on” in the goal, fetch rules and README. Rewrite line 11 to say the current default is `/issues?filter=all` (all issues the user can see) and the new query is narrower involvement. Extend the non-goal to “subscription-only and review-requested work that does not otherwise involve the user,” and state that a subscriber-only item will not appear.

### A2. Freshness has two owners [`egm-comprehension`, `egm-structural`, `egm-zoom-out`] — Severity: High

* **Affected Scope:** [lines 100–114, 140–159, 185–205, 239–244](docs/designs/github_open_work.md#L100-L205) (Component map, Data model, Refresh, Concurrency)
* **Discrepancy Description:** The coordinator authors `OpenWorkStatus`, keeps last attempt/success/error, and publishes `OpenWorkUpdate`; the store also owns `status` and is told to never read coordinator state. `.running` is never published. `refresh()` promises a status return but has none. Failure carry-forward is undefined.
* **Rationale:** Two authors make the header, counts and manual-refresh contract unimplementable. One owner removes five separate findings at once.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Adopt the intermediate Zoom Out recommendation: the store fetches and applies; the coordinator keeps one timestamp. This is a design change, not a wording fix.
* **Proposed Edit:**
  * Location: Component map, Data model, Refresh and failure, Store behavior, Concurrency; implementation items 1, 3, 4, 7, 18–20
  * Change: Delete `OpenWorkUpdate` and `OpenWorkFailure`. Give `OpenWorkStore` `func refresh() async`, which sets `.running`, awaits an injected fetch closure returning `(items: [OpenWorkItem], matchedCount: Int, truncated: Bool)` or throwing, and applies the result itself. Reduce `OpenWorkStatus` to `phase (.idle | .running | .ready)`, `lastSuccess`, `matchedCount`, `truncated`, `errorText`. The coordinator exposes `noteOpenWorkWorkspaceOpened()` and `refreshOpenWorkIfDue()`, and calls the store; nothing flows back. Define failure as: keep items, keep `lastSuccess`, keep `matchedCount` and `truncated`, set `errorText`.

### A3. A second scheduler duplicates existing lifecycle handling [`egm-zoom-out`] — Severity: High

* **Affected Scope:** [lines 185–194, 344–345](docs/designs/github_open_work.md#L185-L194) (Refresh and failure, implementation item 3)
* **Discrepancy Description:** The plan adds `openWorkTask`, an injected interval and sleeper, sleep-cancel/wake-restart rules, a network gate and a skip path. `SyncCoordinator` already owns a 45-second loop, sleep/wake observers and `NWPathMonitor`.
* **Rationale:** A timestamp checked by the existing loop satisfies “every 15 minutes” and “when the view opens” with less state.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** The drift objection to `pollCycleCount % 20` does not apply to a `lastOpenWorkAttempt` timestamp.
* **Proposed Edit:**
  * Location: Refresh and failure; implementation item 3; coordinator tests
  * Change: Remove `openWorkTask`, the injected interval/sleeper and the separate network gate. Add `lastOpenWorkAttempt: Date?`; in the existing polling loop, call `openWorkStore.refresh()` when 15 minutes have elapsed. `MainSplitView.onChange(of: activeWorkspace)` calls `coordinator.noteOpenWorkWorkspaceOpened()`, which refreshes when `lastSuccess` is older than a stated threshold. A manual success resets `lastOpenWorkAttempt`. An offline fetch fails fast and produces the error the view displays.

### A4. The plan does not build in order [`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 330–444](docs/designs/github_open_work.md#L330-L444) (Detailed Implementation Plan); `TriageStore`, `TriageStreamView`, `MainSplitView`, `SettingsView`, `SyncCoordinator`, `GitHubService`
* **Discrepancy Description:** The file list removes `TriageKind` GitHub cases before their consumers, leaves `TriageSource` switches non-exhaustive, and omits live call sites: the Settings notification post, `isFirstLaunchEmptyState`, `getStatus()`’s ETag, the GitHub branches in `archive`/`trash`/`mutateItem`, the `start()` backfill call, and the internal `dismissNotification` call.
* **Rationale:** Almost no intermediate state compiles.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** The five-slice order from the readiness report is the minimum that keeps the tree buildable.
* **Proposed Edit:**
  * Location: Detailed Implementation Plan
  * Change: Reorder into five slices, each with a `swift build` and test gate: (1) types + `fetchOpenWork` + fetch tests; (2) `OpenWorkStore` + store tests; (3) coordinator timestamp/status + coordinator tests; (4) remove GitHub paths from `TriageStore`, `TriageKind`, `GitHubService`, `SettingsView`, `SyncCoordinator`, snapshot decoder; delete `GitHubBackfillTests`; update remaining tests; (5) views, routing, detail, sidebar, onboarding, composition root, README. Add the missing call-site edits to slice 4, and give every `TriageSource` switch an explicit `.gitHub` fallback.

### A5. Type and concurrency contract is incomplete [`egm-comprehension`, `egm-structural`, `egm-implementation-readiness`] — Severity: High

* **Affected Scope:** [lines 125–159, 239–244, 334–340](docs/designs/github_open_work.md#L125-L159) (Data model, Concurrency, items 1–2)
* **Discrepancy Description:** `OpenWorkFetchResult` has no home, `OpenWorkFailure` is undefined, the new types lack `Sendable`/`Identifiable`/`Hashable`, and the `GitHubError` mapping is missing. The `@MainActor` hop is unstated.
* **Rationale:** The fetch contract and app wiring cannot be written without inventing these.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** These are mechanical definitions that remove the remaining implementation choices.
* **Proposed Edit:**
  * Location: Data model; implementation item 1; item 2; Concurrency
  * Change: Put `OpenWorkFetchResult` in `OpenWorkItem.swift` with `items`, `matchedCount`, `truncated`. Declare `OpenWorkItem: Identifiable, Hashable, Sendable` (id = `key`). Declare payloads `Sendable`. Replace `OpenWorkFailure` with `OpenWorkFetchError: Error, Sendable` cases `unauthorized`, `forbidden(resetAt: Date?)`, `notFound`, `server(status: Int)`, `decoding`, `transport`; map from `GitHubError`. If the store fetches, delete the `@Sendable` callback entirely; otherwise specify `{ update in Task { @MainActor in openWorkStore.apply(update) } }`.

### A6. The PAT security claim is false [`egm-structural`, `egm-zoom-out`] — Severity: High

* **Affected Scope:** [line 302](docs/designs/github_open_work.md#L302) (Non-Functional Requirements); `PreferencesStore.swift:30-34`; `DispatchApp.swift:59-70`
* **Discrepancy Description:** The document says the PAT remains in the Keychain and is never written to UserDefaults. `PreferencesStore` persists `dispatch.githubPAT`, and the token provider reads it first.
* **Rationale:** A false security NFR removes the incentive to fix the storage and misleads every later feature.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** The reviewer is correct. The fix belongs in this design because it touches the same settings flow.
* **Proposed Edit:**
  * Location: NFR Security and privacy; implementation item 6; item 7
  * Change: Make the Keychain authoritative. Remove the `githubPAT` property from `PreferencesStore` and its UserDefaults key; read the token only from `AuthService`. Add a one-time migration that deletes `dispatch.githubPAT` if present. Correct the NFR to say the PAT is stored in the Keychain and read from there. Add: PAT validation triggers `openWorkStore.refresh()`.

### A7. Hidden-item state, counts and undo are incoherent [`egm-design`, `egm-structural`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 42, 46, 88, 200–203, 350](docs/designs/github_open_work.md#L200-L203) (Goals, CUJ 4, Store behavior, item 4)
* **Discrepancy Description:** Hiding removes the item from the source array, so undo cannot restore it before a refresh. The coordinator cannot author `hiddenCount`. The 1,000-key cap silently resurrects the oldest hidden item. The existing toast is passive.
* **Rationale:** Hiding is the only write action in the view; it must be reversible and must not lose state.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Keep `allItems` as the source of truth and derive visible items; use an unbounded hidden-key map and one undo slot.
* **Proposed Edit:**
  * Location: Data model; Store behavior; CUJ 4; item 4; item 10
  * Change: Store `allItems`, `hiddenKeys: Set<String>` and `lastHiddenKey: String?`. Derive `visibleItems`, `groupedItems`, `visibleCount` and `hiddenCount` by recomputation, never increment. Remove the 1,000-key cap; hidden keys are a few KB. `hide(key:)` records `lastHiddenKey` and starts a 5–8 second action banner in `OpenWorkView` with an Undo button and a VoiceOver announcement. `unhide(key:)` restores immediately. `restoreAllHidden()` clears the set. A refresh keeps hidden keys for items still present and prunes keys absent from a complete fetch.

### A8. The phase and empty-state machine is undefined [`egm-design`, `egm-structural`, `egm-style`] — Severity: High

* **Affected Scope:** [lines 142, 193, 212–215](docs/designs/github_open_work.md#L212-L215) (Data model, Refresh, Views)
* **Discrepancy Description:** `.stale` is used for every failure, including a first run with no items. The four empty states are not mapped to phase, item count and last-success combinations. The all-hidden state is missing.
* **Rationale:** The view cannot render a correct state without a total mapping.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Three phases plus an optional error and a derived stale flag are smaller than a total function over six tuples.
* **Proposed Edit:**
  * Location: OpenWorkStatus; Refresh and failure; Views
  * Change: Phases: `.idle`, `.running`, `.ready`. Stale is derived: `errorText != nil && !items.isEmpty`. Define renderings: never loaded (`idle`, empty, no error), never loaded with error (`idle + error`), ready and empty (`ready`, empty, no error), ready with items, ready with all items hidden, and ready with a stale error. Each has one header/banner/empty-state combination. Add “Restore all hidden” to the all-hidden state.

### A9. Selection, detail, shortcuts and workspace ownership are unassigned [`egm-design`, `egm-structural`, `egm-implementation-readiness`] — Severity: High

* **Affected Scope:** [lines 219, 370, 390](docs/designs/github_open_work.md#L219-L390) (Views, items 8 and 12); `MainSplitView.swift:35-40,89-125`; `DetailPaneView.swift:20-33,415`
* **Discrepancy Description:** `DetailPaneView`, `Cmd+O` and `Cmd+Shift+A` still read `TriageStore.selectedItem`. `activeWorkspace` stays on `TriageStore` but is never assigned as the routing owner. `isFirstLaunchEmptyState` reads `gitHubItems`. The service used by the detail pane is unstated.
* **Rationale:** Switching workspaces would show the wrong detail or open the wrong URL, and the tree would not compile.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Keep `activeWorkspace` on `TriageStore` and document the dependency; do not add a third router.
* **Proposed Edit:**
  * Location: Views; items 8, 10, 12, 13
  * Change: Declare `activeWorkspace` on `TriageStore` as the routing flag for both stores. In `MainSplitView`, choose the selected item by workspace for `j`/`k`, `e`, `Cmd+O` and `Cmd+Shift+A`. `DetailPaneView` reads `openWorkStore.selectedItem` when GitHub is active and receives `GitHubService` through the environment or the store. Replace `isFirstLaunchEmptyState`’s `store.gitHubItems.isEmpty` with `openWorkStore.visibleCount == 0 && store.gmailItems.isEmpty`. Add `Cmd+O` to the shortcut list.

### A10. The cheaper single-list alternative is not evaluated [`egm-zoom-out`] — Severity: High

* **Affected Scope:** [lines 248–296](docs/designs/github_open_work.md#L248-L296) (Alternatives Considered)
* **Discrepancy Description:** Alternative A rejects only “keep the merged feed and add a status row.” It does not consider deleting the live feed, keeping the existing list, and adding status to the existing store.
* **Rationale:** The document compares the chosen shape only to a strawman. The separate store is defensible, but the reason must be recorded.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Keep the separate `OpenWorkStore` because `TriageStore` selection is `TriageItem`-typed and the Gmail snapshot is persisted. Add the missing alternative and the reason.
* **Proposed Edit:**
  * Location: Alternatives Considered
  * Change: Add “Alternative A2: delete the live feed, keep the existing list, add status.” Pros: smaller diff, one selection model. Cons: `TriageStore` is `TriageItem`-typed; a second item type reopens the snapshot and source-switch complexity; repository grouping and an independent selection still need new state. Reason for rejection: the separate store costs less than widening the persisted type and its merge paths.

### A11. Truncation is computed from the wrong fact [`egm-structural`, `egm-style`, `egm-comprehension`] — Severity: Medium

* **Affected Scope:** [lines 177–180, 214](docs/designs/github_open_work.md#L177-L180) (Fetch, Views)
* **Discrepancy Description:** `truncated = matchedCount > items.count` fires when duplicates are removed from a complete fetch, not only at the 400 cap.
* **Rationale:** A false truncation banner undermines the only completeness signal.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Use the cap, not deduplicated count. Test the duplicate case.
* **Proposed Edit:**
  * Location: Fetch rules; truncation banner; item 18
  * Change: Set `truncated` when the fourth page was fetched and returned 100 items (or when `matchedCount > 400`). Use “Showing 400 of 1,000” as the maximum example, never 1,284. Add a test: four full pages with two duplicates must not set `truncated`; a fifth page existing must set it.

### A12. The header does not express the goal, and count terms are undefined [`egm-style`, `egm-design`, `egm-zoom-out`] — Severity: Medium

* **Affected Scope:** [lines 39, 145–150, 210–216](docs/designs/github_open_work.md#L210-L216) (Goal 5, status, Views)
* **Discrepancy Description:** Goal 5 requires running, last success, matched and shown counts. The header is one string, “89 open · updated 2m ago,” and “updated” is ambiguous. `shownCount`, `hiddenCount` and `visibleCount` have no defined arithmetic.
* **Rationale:** Three surfaces show counts that users cannot reconcile.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Define one term per concept and one header layout.
* **Proposed Edit:**
  * Location: OpenWorkStatus; Views
  * Change: Remove `shownCount`, `hiddenCount`, `requestCount`, `lastAttempt`. Keep `matchedCount` (total_count) and derive `visibleCount` and `hiddenCount` in the store. Header: “`N` visible · `M` matched · refreshed `X` ago,” with the truncation notice on its own line. Sidebar capsule shows `visibleCount`. “Refreshed” always means `lastSuccess`.

### A13. A decode failure can still wipe the snapshot [`egm-structural`] — Severity: Medium

* **Affected Scope:** [line 229](docs/designs/github_open_work.md#L229) (Removals and compatibility)
* **Discrepancy Description:** The tolerant decoder only swallows the GitHub fields. Any other decode failure leaves empty arrays, and the terminate save overwrites the file.
* **Rationale:** The stated protection is incomplete.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Add a load-failure flag and test a corrupt snapshot.
* **Proposed Edit:**
  * Location: Removals and compatibility; `TriageStore` snapshot section; tests
  * Change: Add `didLoadSnapshot: Bool`. If decoding fails, set it false and suppress `saveSnapshotSync` for that launch. Test with a truncated JSON fixture and assert the original file is unchanged.

### A14. The test plan leaves tests that cannot compile [`egm-implementation-readiness`, `egm-codebase-details`] — Severity: Medium

* **Affected Scope:** [lines 411–439](docs/designs/github_open_work.md#L411-L439) (items 17–22)
* **Discrepancy Description:** “Keep” tests construct `.gitHubIssue`/`.gitHubPullRequest`, assert `gitHubItems`, or assert `lastGitHubETag`. The Gmail bootstrap test asserts a GitHub emission. A new `MockURLProtocol` would duplicate the existing one.
* **Rationale:** The test target will not compile after the removal slice.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Enumerate the deletions and keep one shared mock.
* **Proposed Edit:**
  * Location: items 18–22
  * Change: List the exact tests to delete or rewrite in `TriageStoreTests` and `SyncCoordinatorTests`, including `testColdBootstrapSync`’s GitHub assertions. State that the shared URL-protocol mock stays in one file. If the store owns fetch and status, merge `OpenWorkCoordinatorTests` into `OpenWorkStoreTests` and keep only a due-interval assertion for the coordinator.

### A15. Settings and onboarding changes remove shared state and keep stale copy [`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`] — Severity: Medium

* **Affected Scope:** [lines 395, 400, 444](docs/designs/github_open_work.md#L395-L444) (items 13, 14, 23); `SettingsView.swift:25-27,152-156,207-212,409-412`
* **Discrepancy Description:** `errorMessage` and `gitHubStatus` serve Google and PAT flows. Settings has no `OpenWorkStore` environment read for the scope line. The Settings notification post survives the deletion. The PAT copy still requires `notifications`. Onboarding’s “connected test” is a property.
* **Rationale:** The instructions as written either break unrelated settings or leave dead copy.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Narrow the removal to the backfill section and correct the copy.
* **Proposed Edit:**
  * Location: items 13, 14, 23; NFR compatibility
  * Change: Keep `errorMessage`/`gitHubStatus`; remove only the Open Work section, bindings, button and notification post. Add `@Environment(OpenWorkStore.self)` for the scope sentence. Change the PAT scope copy to `repo` only and remove `notifications`. Onboarding: `isConnected` remains `!githubPAT.isEmpty`; say “rename the card and description,” not “keep the connected test.”

### A16. The model and service cleanup is imprecise [`egm-style`, `egm-codebase-details`, `egm-zoom-out`] — Severity: Medium

* **Affected Scope:** [lines 224–230, 340, 405](docs/designs/github_open_work.md#L224-L230) (Removals, item 2, item 15)
* **Discrepancy Description:** `ReviewStatus` and `CheckSuiteStatus` do not contain GitHub cases. “Remove `canonicalKey` if it is no longer referenced” delegates a decision. The old `OpenWork*` helpers collide with the new names. The plan deletes working paging/validation helpers and rebuilds them.
* **Rationale:** An implementer will hit name collisions or leave dead code.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Delete the status enums outright, keep the paging helpers, and enumerate the old helpers.
* **Proposed Edit:**
  * Location: Removals; item 2; item 15
  * Change: Delete `ReviewStatus` and `CheckSuiteStatus`. Delete `canonicalKey`; its uses are in removed merge paths. Keep `requestAllPages`, `nextPageURL`, `validate` and the `OpenWorkIssuePayload` decoder; call `requestAllPages(maxPages: 4)` and map its payloads. Enumerate the old `decodeOpenWork`, `decodeSearchOpenWork`, `mapOpenWork`, `OpenWorkSearchResponse` and `OpenWorkUserPayload` to delete or replace.

### A17. Verification cannot be run as written [`egm-style`, `egm-implementation-readiness`] — Severity: Medium

* **Affected Scope:** [lines 446–453](docs/designs/github_open_work.md#L446-L453) (Verification Plan)
* **Discrepancy Description:** The plan depends on the maintainer’s account, gives no method for a simulated 403 or offline launch, and asks for “no warnings” without a command. The 1,284 example exceeds GitHub’s 1,000 cap. 16 requests/hour is compared with the core limit, not the search limit.
* **Rationale:** Verification must be executable by anyone.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Replace manual network faults with URL-protocol cases and exact commands.
* **Proposed Edit:**
  * Location: Verification Plan; Rate limits
  * Change: Add URL-protocol fixtures for 200, 304/empty, 401, 403 with reset, 5xx, malformed JSON, duplicate pages and five-page responses. Give commands: `swift build`, `swift test --no-parallel`, `swift build -c release`. Print the invariant-to-test table. Compare search requests with the 30-per-minute search limit. Remove the account-specific E2E or label it an observation.

### A18. The green “Live” dot survives the redesign [`egm-design`, `egm-zoom-out`] — Severity: Medium

* **Affected Scope:** [lines 19, 210](docs/designs/github_open_work.md#L19-L210) (Problem, Views); `SidebarView.swift:88-102`
* **Discrepancy Description:** `isLoading` is never set true, so the bottom bar always shows a green dot and “Live.” The plan changes the GitHub row count but not the status bar.
* **Rationale:** A stale header beside a green “Live” indicator fails the design’s own success criterion.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Remove the false indicator rather than adding another status surface.
* **Proposed Edit:**
  * Location: Views; removals; item 9 / `SidebarView`
  * Change: Delete `TriageStore.isLoading` and the bottom status bar, or drive it from `openWorkStore.status.phase` and Gmail sync state. State which in the item list.

### A19. Keyboard and accessibility semantics are inconsistent [`egm-design`, `egm-style`] — Severity: Medium

* **Affected Scope:** [lines 42, 217–219, 310](docs/designs/github_open_work.md#L217-L219) (Goals, Views, NFR)
* **Discrepancy Description:** Goal 8 says `u` and `#` do nothing; the view adds `s`; `e` is missing from the goal. Row labels, absolute dates, badge labels, focus-follow and the removal announcement are unstated.
* **Rationale:** The only destructive shortcut is `e`; its behavior and the screen-reader path must be defined.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Use one shortcut table and one accessibility contract.
* **Proposed Edit:**
  * Location: Goal 8; Views; NFR Accessibility
  * Change: State: `j`/`k` navigate, `e` hides, `u`/`s`/`#` are swallowed and do nothing in Open Work, `Cmd+O` opens on GitHub, `Cmd+Shift+A` dispatches. Rows get labels “title, kind/state, repo#number, author, absolute date.” Focus follows the nearest row after removal; a live-region announcement reports “N items removed” and hide/undo.

### A20. A 400-row backlog has no retrieval beyond grouping [`egm-design`] — Severity: Medium

* **Affected Scope:** [lines 211–217](docs/designs/github_open_work.md#L211-L217) (Views)
* **Discrepancy Description:** The design removes filters and adds no search, kind filter or repository-level hide.
* **Rationale:** The view may be hard to use at the cap.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Stage 8 recommends accepting this trade-off for v1 rather than adding filter state. Record it explicitly.
* **Proposed Edit:**
  * Location: Non-Goals; Future Improvements
  * Change: Add a non-goal: “No search, kind filter or repository-level hide in v1; repository grouping, updated order and per-item hide are the retrieval model.” Add a future improvement for repository-level hide if noise becomes a problem.

### A21. Cold-start behavior contradicts the product claim [`egm-zoom-out`, `egm-comprehension`] — Severity: Medium

* **Affected Scope:** [lines 54, 152, 322](docs/designs/github_open_work.md#L54-L152) (Non-Goals, status, Future Improvements)
* **Discrepancy Description:** Items are never persisted, so every launch shows “not imported yet” and offline launch shows nothing. The README sells instant cold start.
* **Rationale:** A blank GitHub workspace on every launch is a product regression, not just a deferred feature.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Persist a last-run summary, not items. Keep the item list in memory.
* **Proposed Edit:**
  * Location: Data model; Store behavior; Non-Goals; README item
  * Change: Persist `lastSuccess`, `matchedCount`, `truncated` and `errorText` in UserDefaults under `dispatch.openWorkLastRun`. Show “Last refreshed X ago · N matched” while the first fetch runs. Say “not refreshed in this launch,” not “not imported.” Document that the list itself is fetched on open.

### A22. Multiple windows create multiple coordinators [`egm-structural`] — Severity: Medium

* **Affected Scope:** [line 365](docs/designs/github_open_work.md#L365) (Composition root)
* **Discrepancy Description:** `WindowGroup.onAppear` runs `setupServicesAndSync()` per window, creating a second `SyncCoordinator`; the shared store receives both.
* **Rationale:** The “only one refresh at a time” guarantee is actor-local and protects nothing across windows.
* **AI Suggestion:** PROPOSE FIX
* **Justification:** Create the coordinator once at app level.
* **Proposed Edit:**
  * Location: item 7
  * Change: Move coordinator creation out of `MainSplitView.onAppear` into an app-level `@State` or a singleton guard. Add a test or a note that a second window reuses the same coordinator and store.

### A23. Remaining specification gaps and nits [`egm-*`] — Severity: Low

* **Affected Scope:** various
* **Discrepancy Description:** “At most ten” in Alternative D; wrong `total_count` citation; “400 of 1,284”; search-versus-core quota; terminology drift; missing paths; unused `labels`/`authorAvatarURL`; `TriageSource.gitHub` has no producer; old hidden key; account-specific numbers; Goal 10 as a goal; Alternative C heading; unchanged file item; `selection` versus `selectedKey`.
* **Rationale:** These do not block implementation but make the document inconsistent.
* **AI Suggestion:** PROPOSE FIX for the factual contradictions; DECLINE for formatting preferences.
* **Justification:** Fix the contradictions an implementer would act on; leave cosmetic structure alone.
* **Proposed Edit:**
  * Location: Alternative D line 272; Problem line 23; Views line 214; Rate limits; Additional Resources; Data model; item 9; item 16
  * Change: Change “at most ten” to “at most four.” Cite `GitHubService.swift:161-164` for `total_count`. Change “1,284” to “1,000.” Compare with the search quota. Add repository-root paths to Additional Resources. Remove `labels` and `authorAvatarURL` if the row does not render them. Delete `dispatch.dismissedGitHubIssueIDs` in the migration. Label 89/52 as the maintainer’s observation. Move Goal 10 to a constraints note or rename it. Delete the “No change” file item. Standardize on `selectedKey`.
  * **DECLINE:** promoting `Additional Resources`/`Future Improvements` to H2, and the `selection`/`selectedKey` renaming beyond a one-line note.
  * **ESCALATE:** Whether fine-grained PATs and SSO organizations must be supported in v1 (Open Question 1). This depends on the audience, not on the document or the code.

## Resolution Summary

| Category | Count |
| --- | --- |
| Accepted and applied | 22 (A1–A22, plus the factual fixes in A23) |
| Contested | 1 (adding review-requested work in A1; the copy correction was applied) |
| Escalated | 1 (fine-grained/SSO support in A23) |
| Declined | 2 (H2 promotion, cosmetic renaming) |
| Remaining unaddressed | 1 (the escalated question) |

### Applied changes

* Scope copy now names authored, assigned, mentioned and commented work, and records subscription-only and review-requested items as excluded.
* `OpenWorkStore` owns the fetch, status, hidden state and selection. `OpenWorkUpdate` and `OpenWorkFailure` are removed.
* The coordinator owns one `lastOpenWorkAttempt` timestamp inside the existing loop. The second timer, injected sleeper and network gate are removed.
* The implementation plan is reordered into five buildable slices, with Settings and Onboarding before the PAT removal and model cleanup last.
* The PAT is Keychain-only, with a migration that deletes the UserDefaults copy.
* Hidden keys are unbounded, counts are derived, and undo uses a 5–8 second action banner.
* Phases are `.idle`, `.running`, `.ready`; staleness is derived. Empty states and the all-hidden state are mapped.
* Detail, shortcuts and `activeWorkspace` routing are assigned, including `Cmd+O`.
* `OpenWorkFetchResult` and `OpenWorkFetchError` are defined; conformance and actor-hop requirements are stated.
* The truncation rule, header counts, cold-start summary, multi-window guard, snapshot no-overwrite flag, accessibility contract and test matrix are specified.
* Alternative A2 is added, the request-count contradiction is fixed, and the `total_count` citation is corrected.

### Escalated for the owner

**Fine-grained PAT and SSO support.** Whether Open Work must work for fine-grained tokens and SSO-protected organizations is a product decision. The design currently documents it as a limitation.

### Declined

* Promoting `Additional Resources` and `Future Improvements` from H3 to H2 (cosmetic).
* Renaming `selection` or other internal identifiers beyond the `selectedKey` standard (cosmetic).

The design document at `docs/designs/github_open_work.md` has been updated. No source files were changed.
