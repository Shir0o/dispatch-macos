# Goldfish Review Report — Critic Stage (Post-Resolution)

**Target:** `docs/designs/github_open_work.md` (FeatureRange 1–346)

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-design` | completed |
| `egm-structural` | completed |
| `egm-style` | completed |

## Verdict

The previous structural objections are resolved: one query, one status owner, a coordinator timestamp, and the five buildable slices are in place. The document is still not implementable without guessing, and two findings violate its own headline invariant that a failed refresh cannot delete or resurrect work. The remaining blockers are concentrated in four areas: the fetch's completeness signal, the hidden-key lifecycle, the agent-dispatch rewrite, and the removal call sites.

## Blocker Findings

### B1. The dispatch path has no source after the model cleanup — Severity: Blocker

* **Reviewer Lens:** structural, design
* **Affected Scope:** line 218, line 230; `MainSplitView.swift:89-152`; `DetailPaneView.swift:20-65,415`
* **Discrepancy:** “`⌘⇧A` agent dispatch” is retained, but the path is typed to `TriageItem` and `TriageKind`. Removing the GitHub cases and `gitHubItems` leaves both call sites uncompilable, and `DetailPaneView` still routes on `TriageStore.selectedItem`. The design never says how `OpenWorkItem` builds `AgentDispatchPayload`.
* **Rationale & Recommendation:** Name the rewrite: `dispatchCurrentItem()` reads `openWorkStore.selectedItem` when GitHub is active, builds the payload from `repository`, `number` and `title`, and keeps `preferredStore.localPath(for:)`. The detail router reads the Open Work item for GitHub. State that `TriageItem` no longer carries GitHub work.

### B2. The fetch cannot signal completeness — Severity: Blocker

* **Reviewer Lens:** structural, zoom-out, style
* **Affected Scope:** lines 168, 171, 173, 182, 328; `GitHubService.swift:336-357`
* **Discrepancy:** The plan reuses `requestAllPages`, which returns the pages collected when a page 404s and does not expose whether pagination stopped at the cap or naturally. A 404 on page 2 returns page 1 as a successful result; the store replaces the list and prunes hidden keys. `matchedCount` has no rule when no page is returned.
* **Rationale & Recommendation:** Give the fetch an explicit contract: return `(pages, stoppedAtCap, complete)` or own pagination in `fetchOpenWork`. Any non-2xx on any page throws. Replace items on any success; prune hidden keys and drop closed items only when `complete && !truncated`.

### B3. Truncated runs prune hidden keys — Severity: Blocker

* **Reviewer Lens:** zoom-out, structural, design
* **Affected Scope:** lines 171, 182, 202, 328
* **Discrepancy:** A truncated 400-item result is treated as a complete result for pruning. Hidden keys for items outside the window are deleted and resurrect when those items re-enter the window. Line 202 calls the set unbounded while line 182 bounds it.
* **Rationale & Recommendation:** Prune only when `!truncated`. State that hidden keys are otherwise unbounded and that truncation suppresses pruning. Do not key solely on `owner/repo#number`; a repository rename or transfer changes it. Use GitHub's numeric issue `id` as the stable key if available, or state the rename limitation.

### B4. “Complete” is undefined — Severity: Blocker

* **Reviewer Lens:** comprehension, structural, style
* **Affected Scope:** lines 13, 37, 182, 185, 328
* **Discrepancy:** “Complete run”, “complete result” and “successful refresh” are used interchangeably. A fresh reader cannot tell whether `truncated == true` counts. The term decides whether rows are replaced and hidden keys pruned.
* **Rationale & Recommendation:** Define once: complete = `!truncated` after a full pagination pass with no error. Replace on any success; drop closed items and prune only on a complete run. Use one term throughout.

### B5. The freshness contract still has two owners — Severity: Blocker

* **Reviewer Lens:** zoom-out, structural, style, comprehension
* **Affected Scope:** lines 190–193, 249, 327
* **Discrepancy:** `lastOpenWorkAttempt` is described as set by success only, so a 401 retries every 45 seconds. “A manual success resets `lastOpenWorkAttempt`” cannot be observed by a coordinator that “never reads store state.” `noteOpenWorkWorkspaceOpened()` loads the persisted last-run summary, making the coordinator a second reader/writer of store state.
* **Rationale & Recommendation:** Stamp `lastOpenWorkAttempt` before invoking the fetch, independent of outcome. The store hydrates the persisted last-run summary in `init`. Drop the manual-reset sentence, or route Refresh through `coordinator.refreshOpenWorkNow()`. State whether `hasOpenedOpenWork` ever resets and whether wake calls `refreshOpenWorkIfDue()`.

### B6. The removal list still leaves live call sites — Severity: Blocker

* **Reviewer Lens:** zoom-out, structural
* **Affected Scope:** lines 225, 229–234; `MainSplitView.swift:35-40`; `SettingsView.swift:51,143`; `DispatchApp.swift:89-93`; `TriageStore.swift:140-145,318-319,356-419,477,512-518`
* **Discrepancy:** The plan claims to preserve buildability but does not name: `MainSplitView`'s `preferencesStore.githubPAT` read, Settings' `tempGitHubPAT` prefill and clear, `DispatchApp`'s `setOnBackfillUpdated` call, `TriageStore.loadSnapshot`'s `gitHubItems`/`dismissedGitHubKeys` writes, `selectedItem`'s GitHub fallback, `mutateItem`, `star`, `archive`, `trash`, and `streamTitle`'s `gitHubFilter`.
* **Rationale & Recommendation:** Enumerate these by file and line. Replace `isFirstLaunchEmptyState`'s GitHub test with a Keychain configuration check, not `visibleCount == 0`, or onboarding overlays a legitimately empty Open Work view.

### B7. The migration drops the real prior hidden state — Severity: Blocker

* **Reviewer Lens:** structural
* **Affected Scope:** lines 204, 234; `TriageStore.swift:35,319,334`
* **Discrepancy:** The live dismissal set is `SnapshotData.dismissedGitHubKeys`, not `dispatch.dismissedGitHubIssueIDs`. The plan deletes the latter and ignores the former, so every previously archived GitHub item returns.
* **Rationale & Recommendation:** Decode `dismissedGitHubKeys` from the old snapshot once and seed `dispatch.openWorkHiddenKeys` before discarding the old field. Test the migration with a real old snapshot.

## Major Findings

### M1. The PAT migration deletes the only stored token — Severity: Major

* **Reviewer Lens:** comprehension, style
* **Affected Scope:** line 225; item 18 line 454; NFR Security line 314
* **Discrepancy:** The current app reads `preferencesStore.githubPAT` first, and validation writes only to UserDefaults. The migration deletes the defaults key without copying it to the Keychain first, disconnecting every existing user.
* **Recommendation:** Copy to Keychain, verify the write, then delete. Name the trigger and the failure path. Add a risk entry. Reconcile the “`repo` only” copy with the fine-grained-token claim; fine-grained tokens use permissions, not scopes.

### M2. The list has no global recency order — Severity: Major

* **Reviewer Lens:** design
* **Affected Scope:** lines 54, 200
* **Discrepancy:** The document says “updated order” is part of the retrieval model, but groups sort by repository name, so the top of the screen is alphabetical, not the most recently changed work.
* **Recommendation:** Sort groups by the newest item's `updatedAt` descending, tie-break by repository name. Keep items inside a group sorted by `updatedAt`.

### M3. A failed first refresh shows a matched count above an empty list — Severity: Major

* **Reviewer Lens:** design, style
* **Affected Scope:** lines 146–154, 183, 211, 214, CUJ 5
* **Discrepancy:** A persisted “89 matched” plus a failed first fetch renders “89 matched · refreshed 2h ago” with no rows. The count contradicts the body, and the user cannot tell “nothing open” from “nothing loaded.”
* **Recommendation:** Define header variants by data availability: “Not loaded this session · last refresh 2h ago · 89 matched” when no items exist; show “N visible” only after a fetch produces items.

### M4. Error recovery is not error-specific — Severity: Major

* **Reviewer Lens:** design
* **Affected Scope:** lines 144, 173, 213, 327
* **Discrepancy:** A revoked PAT gets a Retry button that cannot succeed. A 403 carries a reset time the banner never shows. `notFound` has no producer and other 4xx responses are unmapped.
* **Recommendation:** 401 → “Update token” opens Settings; 403 → “Retry at HH:MM,” disabled until reset; transport/5xx/decoding → Retry. Map 404 and other 4xx explicitly or remove `notFound`.

### M5. The counts cannot be reconciled — Severity: Major

* **Reviewer Lens:** design, style
* **Affected Scope:** lines 199, 209, 211, 212
* **Discrepancy:** Hiding one item yields “88 visible · 89 matched” with no hidden count, which reads as unexplained loss. The truncation line hardcodes 400/1,000 and counts hidden rows as shown.
* **Recommendation:** “88 visible · 1 hidden · 89 matched.” Truncation: “400 fetched · 1,000 matched (capped),” interpolated, and state that deduplication can reduce the fetched count.

### M6. Undo can expire before its banner does — Severity: Major

* **Reviewer Lens:** design, structural
* **Affected Scope:** lines 88, 202, 219
* **Discrepancy:** `lastHiddenKey` is cleared by a successful refresh, so a 15-minute refresh inside the 5–8 second banner leaves a visible Undo that restores nothing. `u` does nothing and `Cmd+Z` is unspecified.
* **Recommendation:** Clear `lastHiddenKey` only when the banner expires or a new hide replaces it. Bind `Cmd+Z` to the last hide. Test hide → refresh completes → undo.

### M7. Hiding is not fully reversible — Severity: Major

* **Reviewer Lens:** design, structural, style
* **Affected Scope:** lines 42, 88, 217
* **Discrepancy:** “Undoable” and “restores hidden items from the header menu” imply per-item restore, but only `restoreAllHidden()` exists, and the banner lasts 5–8 seconds. The only inverse after that is a bulk, unconfirmed restore.
* **Recommendation:** Add per-item restore, or say “undo within the banner; afterwards Restore all hidden.” Define N as keys present in `allItems`, not all persisted keys.

### M8. `total_count` has no carrier after the cleanup — Severity: Major

* **Reviewer Lens:** zoom-out, structural, style
* **Affected Scope:** lines 169, 231; `GitHubService.swift:432-434`
* **Discrepancy:** The plan deletes `OpenWorkSearchResponse`, the only search wrapper, while requiring `total_count`. `OpenWorkIssuePayload` is a flat issue record.
* **Recommendation:** Keep and extend `OpenWorkSearchResponse` with `total_count`, or name the decode type in the fetch contract.

### M9. "Why is this item here" is claimed as solved but excluded — Severity: Major

* **Reviewer Lens:** design, style, zoom-out
* **Affected Scope:** lines 17, 45, 136, 339
* **Discrepancy:** The Problem asks why an item is present, and the success criterion requires the user to tell why an item is missing or stale. The design has no relationship field and defers it. The success wording quietly changes the question.
* **Recommendation:** Either add a relationship badge in v1 or make the omission a non-goal and rewrite the Problem/Success so it does not claim a solved question.

### M10. The product value is still unnamed — Severity: Major

* **Reviewer Lens:** zoom-out, style
* **Affected Scope:** lines 11–13, 306–308
* **Discrepancy:** The Overview names changes, not the job. Alternative H admits the feature has no named advantage over `github.com/issues`.
* **Recommendation:** Add one sentence: one window with Gmail, repository grouping, local hide, and `⌘⇧A` dispatch. State the job the view does better.

### M11. Single-flight refresh has no mechanism — Severity: Major

* **Reviewer Lens:** structural
* **Affected Scope:** lines 180–184
* **Discrepancy:** `refresh()` awaits an async closure on `@MainActor`; a second call can interleave at the await. `.running` is not a guard. “Awaits the in-flight call” needs a stored task.
* **Recommendation:** Specify `private var inFlight: Task<Void, Never>?`; return `await inFlight.value` when present, otherwise create and store a task, clearing it in `defer`.

### M12. Error mapping is unassigned — Severity: Major

* **Reviewer Lens:** structural
* **Affected Scope:** lines 144, 173; `GitHubError`
* **Discrepancy:** `missingToken` and `invalidURL` have no `OpenWorkFetchError` case. It is unstated whether `fetchOpenWork` wraps `GitHubError` or the store switches on it. `fetchAction` is untyped `throws`.
* **Recommendation:** `fetchOpenWork` catches every `GitHubError` and rethrows `OpenWorkFetchError`, mapping `missingToken` to `unauthorized` or a new `.notConfigured`, and `invalidURL` to `.transport`. The store switches exhaustively.

### M13. `fetchAction` cannot be held and wired after construction — Severity: Major

* **Reviewer Lens:** comprehension, structural
* **Affected Scope:** lines 181, 373, 390
* **Discrepancy:** The store “holds” a non-optional `fetchAction`, while the composition root wires it after construction. No initializer signature or mutability is stated, and Settings validation calls `refresh()` directly.
* **Recommendation:** Make it an initializer parameter or a settable optional with a defined pre-wiring behavior. State the coordinator closure's isolation (`@MainActor @Sendable` or an explicit `await`).

### M14. The first fetch has no call site — Severity: Major

* **Reviewer Lens:** comprehension
* **Affected Scope:** line 191; items 7 and 10
* **Discrepancy:** `noteOpenWorkWorkspaceOpened()` has behavior but no caller. The loading state, CUJ 1 and the `hasOpenedOpenWork` gate all depend on it.
* **Recommendation:** Name the caller (`MainSplitView.onChange(of: store.activeWorkspace)` or an `OpenWorkView.task`). State whether `hasOpenedOpenWork` ever resets and whether wake calls the due check.

### M15. The agent-dispatch contract is undefined — Severity: Major

* **Reviewer Lens:** comprehension
* **Affected Scope:** Overview, lines 108, 218–219, item 12
* **Discrepancy:** “Dispatch to agent”, `AgentCLI`, `TerminalApp` and the payload are retained but never described. The only non-read-only feature the design keeps cannot be implemented from the text.
* **Recommendation:** Add one sentence on the app's shape and one on the dispatch contract: what launches, what the agent receives, and what happens with no agent or terminal configured.

### M16. The snapshot rollback claim is unproven — Severity: Major

* **Reviewer Lens:** structural, style, zoom-out
* **Affected Scope:** lines 234, 318, 329; `TriageStore.swift:28-35`
* **Discrepancy:** “Stop writing new values” for `gitHubItems` is ambiguous. If the key is omitted, the old build's non-optional decoder fails and the next save overwrites the cache. `didLoadSnapshot` as written suppresses the first save on a fresh install and only the next save on a corrupt file.
* **Recommendation:** Keep writing `gitHubItems: []`. Define `didLoadSnapshot = true` when no file exists, and suppress saves for the launch after a decode failure, not just the next save.

## Nit Findings

- **N1.** `OpenWorkFetchResult` is not declared `Sendable`, though it crosses the actor boundary.
- **N2.** Truncation is falsely true when exactly 400 results exist and page 4 returns 100 with no next link. Use `matchedCount > 400` or require a next link.
- **N3.** “Wake triggers one due check” is false in the current code; `handleSystemDidWake` restarts the loop and calls `performSyncCycle`.
- **N4.** The migration key `dispatch.dismissedGitHubIssueIDs` is deleted in Slice 2 and again in Slice 5. Assign it once.
- **N5.** `activeWorkspace` is load-bearing but not listed among the properties `TriageStore` keeps.
- **N6.** Goal 5 requires running state; the header spec has no running element. Specify the Refresh button's running label.
- **N7.** `AuthService`, the token provider and the `GitHubError` mapping are used as contracts without definition.
- **N8.** Detail-fetch failures are outside `OpenWorkFetchError`; say whether a 401/403 is shown inline or leaves the list untouched.
- **N9.** Row dates are relative in the visual row and absolute in the accessibility label; specify both roles.
- **N10.** “Three components change role” is followed by four bullets.
- **N11.** “One timestamp” is followed by two fields (`lastOpenWorkAttempt`, `hasOpenedOpenWork`).
- **N12.** `selection` and `selectedKey` are used interchangeably.
- **N13.** `GitHubService` is called “unchanged” while it gains a method; say the concurrency model is unchanged.
- **N14.** The removal list names “cases” on `ReviewStatus` and `CheckSuiteStatus`, which contain no GitHub cases; delete the enums outright.
- **N15.** The Settings scope sentence says “refreshes every 15 minutes” unconditionally, but refresh is gated on the workspace having been opened.
- **N16.** “Already failing visibly” contradicts the Problem's claim that failures are silent.
- **N17.** The `tags` mistake is referenced without explanation.
- **N18.** Key stability is claimed, but a repository rename or transfer changes `owner/repo#number`.

## Open Questions

1. Does a truncated success count as complete for replacement and pruning?
2. Who owns the persisted last-run summary: store `init` or workspace open?
3. Is Refresh a store call or a coordinator call, and does it move the next due time?
4. Is 400 the right cap for a user whose organization has thousands of open items?
5. Do fine-grained PATs and SSO organizations need explicit support in v1?
