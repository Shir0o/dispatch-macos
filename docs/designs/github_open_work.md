# GitHub Open Work Import

* **Author:** Dispatch maintainer
* **Status:** Proposed
* **Date:** 2026-11-09

--------------------------------------------------------------------------------

## Overview

Dispatch's GitHub workspace currently combines two feeds: a live search for open issues assigned to the authenticated user, polled every 45 seconds, and a backfill that imports open issues and pull requests the user is involved with, refreshed every 15 minutes and merged into the same list. The current default backfill calls `/issues?filter=all`, which returns every open issue the user can see, not only work that involves them. This design replaces both feeds with one **Open Work** view backed by one involvement query, held in memory and refreshed every 15 minutes after the workspace is opened.

The change removes the merge engine, the assigned-issue poller, the GitHub smart filters, the two dismissal stores, and the free-text owner and repository fields. Imported work gets its own selection, counts, and status. It is never counted as unread. A refresh replaces the list on every success; only a complete run drops hidden keys. A failed run keeps the previous list and reports the error. Open Work keeps the user's GitHub work in the same window as Gmail, grouped by repository, with local hide and `⌘⇧A` dispatch.

## The Problem

The current GitHub side cannot answer three basic questions: did the refresh run, what changed, and why is the list stale or truncated.

**The UI reports success no matter what happened.** Each per-repository or per-owner fetch is wrapped in `try?` and returns an empty array on failure (`GitHubService.swift:255-279`). The coordinator catches every remaining error and does nothing (`SyncCoordinator.swift:161-164`). A missing token, a 403, a repository the token cannot read, and a genuinely empty result all render the same. `isLoading` is never set true (`TriageStore.swift:77`), so the sidebar shows a green "Live" dot even when sync has been failing for hours. "Backfill Now" posts a notification that only the main window's scene listens for (`SettingsView.swift:189-194`, `DispatchApp.swift:25-37`); with the main window closed it does nothing, and a second click during a run also returns silently (`SyncCoordinator.swift:149`).

**A partial result replaces the whole set.** The visible list is rebuilt from exactly what the last fetch returned (`TriageStore.swift:216-224`). One failed source therefore deletes that source's rows. Because dismissals are pruned by intersecting with the same result (`TriageStore.swift:219`), a failed source also loses the record of what the user dismissed, so those items return on the next successful run. Two different dismissal stores exist, keyed differently, and neither applies to the other (`TriageStore.swift:91-97`, `163-172`).

**Caps are silent.** The default is three pages per source, or 300 items (`GitHubService.swift:236`). The store truncates to 500 by array position (`TriageStore.swift:64-70`, `198-202`), and GitHub caps search at 1,000. The live search decodes `total_count` and discards it (`GitHubService.swift:161-164`), while the backfill payload type does not decode it at all (`GitHubService.swift:432-434`). A user cannot distinguish a complete list from a truncated one.

**The UI treats a backlog as an inbox.** Imported items arrive read (`GitHubService.swift:524`), so the GitHub unread badge can show zero while hundreds of rows exist (`TriageStore.swift:176-183`). The empty state says "All Caught Up" whether the fetch returned nothing or failed (`TriageStreamView.swift:41-58`). The smart filters cannot match imported pull requests because review and CI status are hardcoded (`GitHubService.swift:499-506`). Archive and Trash only hide an imported item locally (`TriageStore.swift:356-360`, `415-419`), but the detail pane labels them as notification actions (`DetailPaneView.swift:245-260`), and there is no undo or list of hidden items.

**The live feed duplicates the import and fights it.** The live feed is `is:issue is:open assignee:@me` (`GitHubService.swift:115`), a subset of an involvement query. It creates items as unread (`GitHubService.swift:195`), re-emits them every 45 seconds, and preserves local read state only for imported items (`TriageStore.swift:262-265`). Pressing `u` on an assigned issue is reverted within one poll, and that item is counted in the badge.

**Scope is configured by guesswork.** Settings accepts free-text owner and repository lists and runs them as a union (`GitHubService.swift:250-288`). Malformed lines are silently dropped while remaining on screen (`GitHubService.swift:292-332`). The copy says the repository list narrows the import, but filling both lists imports everything the owners own (`SettingsView.swift:184`). Adding your own account as an owner imports every open issue across all your repositories, including other people's work, and then truncates at 500.

The published application is ad-hoc signed and not notarized, and its Google refresh token is stored but never used. Those are separate release and authentication defects. They are not solved here, but they make the same screens untrustworthy, so this design must not add another silent failure on top of them.

## Goals

1. Replace the merged GitHub list with one **Open Work** view that shows every open issue and pull request involving the authenticated user within the token's access: authored, assigned, mentioned, or commented on.
2. Use one involvement query with no owner or repository configuration. Remove the free-text fields.
3. Refresh every 15 minutes after the GitHub workspace is first opened in a launch, and on that first open. Replace the list on every success; drop hidden keys only after a complete run.
4. On failure, keep the previous set, leave the last-success time unchanged, and show the error. Never delete rows because a fetch failed.
5. Show in the view header: running state, visible count, hidden count, matched count, updated count, last successful refresh, and a truncation notice when the 400-item cap is reached.
6. Group items by repository, keep the selected item across refreshes, and drop closed and merged items on the next successful refresh.
7. Never count an imported item as unread. The GitHub sidebar row shows a neutral count of visible open items, not an unread badge.
8. Provide two row actions: "Open on GitHub" and "Hide from Open Work". Hiding is local, undoable, and its keys persist across relaunch. `u`, `s` and `#` show “Not available in Open Work”; `e` hides and is labelled in the shortcut legend.
9. Remove the live assigned-issue feed, its ETag polling, `GitHubFilter`, the sidebar filter section, `mergedGitHubItems`, `isBackfillDerived`, and both existing dismissal stores.

Success means a user can open the GitHub workspace and tell within one screen whether the refresh ran, what changed, how many items matched and are visible, and why the list is stale or truncated. It also means a failed refresh cannot make work disappear or resurrect work the user hid.

## Non-Goals

* Changing GitHub state. Dispatch will not close issues, merge pull requests, mark notifications read, or unsubscribe from anything from Open Work.
* Review-requested and subscription-only work that does not otherwise involve the user. GitHub's `involves:@me` qualifier covers authored, assigned, mentioned and commented-on items; it does not cover subscription or review-requested status. A subscriber-only item will not appear, and the view copy must say so.
* Per-item relationship reasons (assigned, authored, mentioned). The query returns involvement, not the reason. Relationship badges are deferred.
* A hidden-items sheet with per-item restore. Undo plus “Clear all hidden keys” is the v1 inverse.
* Importing every open item in every repository the token can read, including other people's backlog.
* Fetching CI or review metadata for imported pull requests. Unknown values remain unknown.
* Persisting imported items across relaunch in this version. Only hidden keys and the last-run summary persist.
* A search box, kind filter or repository-level hide. Repository grouping, newest-first ordering and per-item hide are the retrieval model in this version.
* Gmail behavior, a general notification feed, multi-account support, and macOS signing or notarization.
* Guaranteed completeness above the GitHub search limit. The view discloses truncation instead.
* Explicit fine-grained PAT and SSO organization support. The view states that the scope is what the token can read; this is a documented v1 limitation.

## Open Questions

* **Question 1**: Do fine-grained personal access tokens and SSO-protected organizations need explicit support beyond the documented v1 limitation?

--------------------------------------------------------------------------------

## Critical User Journeys (CUJs)

### CUJ 1: First open after a token is saved

* **Given**: A valid PAT is stored and no Open Work data has been fetched in this launch.
* **When**: The user selects the GitHub workspace.
* **Then**: `OpenWorkView.task` calls `noteWorkspaceOpened()`, the view shows “Loading Open Work…”, runs one involvement search, and renders the results grouped by repository. The header reads “89 visible · 0 hidden · 89 matched · 0 updated” and “last successful refresh just now”. The GitHub sidebar count shows 89, not an unread count. No item carries an unread dot.

### CUJ 2: A refresh fails

* **Given**: 89 items are visible from an earlier successful run.
* **When**: the 15-minute refresh receives HTTP 403, 401, or a network error.
* **Then**: the 89 rows remain. The header keeps the previous last-success time and marks the data stale. The banner shows the matching action: “Update token” for 401, “Retry at HH:MM” for 403 with a reset time, “Update token” for 403 without one, or Retry for transport and server errors. Hidden items stay hidden. No hidden key is pruned.

### CUJ 3: Work closes upstream

* **Given**: Item `owner/repo#42` is visible and selected.
* **When**: a successful refresh no longer returns it because the issue was closed or the pull request merged.
* **Then**: The row disappears, selection moves to `visibleCount == 0 ? nil : min(previousIndex, visibleCount - 1)` in the grouped order, and a transient notice reports how many items left the list.

### CUJ 4: Hiding an item

* **Given**: An item is visible in Open Work.
* **When**: The user presses `e` or chooses “Hide from Open Work”.
* **Then**: The row disappears and a 6-second action banner offers Undo. The key is written to UserDefaults. `Cmd+Z` repeats the last undo while the banner is alive. After relaunch, the item remains hidden until the user chooses “Clear all hidden keys”.

### CUJ 5: Offline launch

* **Given**: The app has no network and no Open Work data in memory, but a previous run is recorded.
* **When**: The user opens the GitHub workspace.
* **Then**: The header reads “Not loaded this session · last successful refresh 2h ago · 89 matched”, the view reports the network failure, and Retry is offered. It does not say “All Caught Up” and does not claim the list is current.

## Technical Plan (Architecture)

### Component map

```text
GitHubService.fetchOpenWork()          one involvement search, own pagination, ≤4 pages
        │ OpenWorkFetchResult(items, matchedCount, fetchedCount, truncated, complete)
        ▼
OpenWorkStore (@MainActor, @Observable)
        │ fetchAction, allItems, hiddenKeys, status, selection, groups,
        │ lastAttempt, hasFetchedThisLaunch, hasOpenedOpenWork, isConfigured,
        │ undoDeadline, bannerTask, canUndo, refreshGeneration, refreshTask
        ├── SidebarView                 neutral visible count
        ├── OpenWorkView                grouped list, header, state table, undo
        └── DetailPaneView              Open on GitHub, Hide, Dispatch to agent

SyncCoordinator (actor)                45-second loop and wake call
                                       openWorkStore.refreshIfDue()
```

One component is new; three change role:

* `GitHubService` gains `fetchOpenWork` and loses the per-repository and per-owner fan-out.
* `OpenWorkStore` is new. It owns fetch, status, hidden keys, selection, the refresh clock and the last-run summary.
* `SyncCoordinator` stops merging and stops tracking backfill timestamps. Its loop and wake handler call one store method.
* `TriageStore` becomes Gmail-only. Its GitHub arrays, filters and merge helpers are removed. The views still read `activeWorkspace` from it.

### Contracts

These five rules are stated once and referenced elsewhere.

1. **Success versus completeness.** `applySuccess(result)` always replaces `allItems`, sets `phase = .ready`, clears `error`, sets `lastSuccess = now()`, and updates `matchedCount`, `fetchedCount`, `truncated` and `updatedCount`. `canPrune = complete` only gates hidden-key pruning. A truncated success still updates the header and replaces the visible list.
2. **No read before write.** `LegacyStateMigrator.run(defaults:)` runs before `OpenWorkStore` is constructed. It copies the PAT to the Keychain with a synchronous helper, seeds `dispatch.openWorkHiddenKeys` from the old snapshot and defaults, and only then deletes the old keys. `OpenWorkStore.init` receives the resulting `isConfigured` value.
3. **Owner before `body`.** `DispatchApp.init` constructs `AuthService`, `GitHubService`, `OpenWorkStore` and `SyncCoordinator` as root state. `setupServicesAndSync()` only wires callbacks and starts the coordinator; it does not create the store.
4. **Status carries identity.** `OpenWorkStatus` carries `error: OpenWorkFetchError?`. The view maps each case to one action; it never matches user-facing text.
5. **One refresh task, one dispatch builder, one state table.** `OpenWorkStore.refreshTask` is the only in-flight handle. `OpenWorkDispatcher.makePayload(item:detail:)` and `performDispatch(payload:preferences:)` are the only payload/dispatch pair. The view states are defined in one table under Views.

### Data model

**`OpenWorkItem`** is a separate value type, not a `TriageItem`. Imported work is not triage mail, and keeping it out of `TriageItem` avoids changing a type that is persisted in the Gmail snapshot.

* `key: String` — `owner/repo#number`, lowercased, stable within a repository.
* `repository: String` — `owner/repo`, preserving display case.
* `number: Int`
* `kind: .issue | .pullRequest`
* `title: String`
* `authorLogin: String`
* `updatedAt: Date`
* `webURL: URL`

Conformances: `Identifiable` (id = `key`), `Hashable`, `Sendable`. `OpenWorkItemKind` is `Hashable` and `Sendable`.

**`OpenWorkFetchResult`** is the fetch payload:

* `items: [OpenWorkItem]`
* `matchedCount: Int` — GitHub's `total_count`, capped by GitHub at 1,000.
* `fetchedCount: Int` — unique items returned, after deduplication.
* `truncated: Bool`
* `complete: Bool` — true when `!truncated` and every page returned 2xx and pagination ended with no next link.

Conformance: `Sendable`.

**`OpenWorkFetchError`** maps from `GitHubError`. Cases: `notConfigured`, `unauthorized`, `forbidden(resetAt: Date?)`, `notFound`, `server(status: Int)`, `decoding`, `transport`. It is `Error, Sendable`. `fetchOpenWork` performs the mapping; the store never switches on `GitHubError`.

**`OpenWorkStatus`** is what the view reads:

* `phase: .idle | .running | .ready`
* `lastSuccess: Date?`
* `matchedCount: Int`
* `fetchedCount: Int`
* `truncated: Bool`
* `updatedCount: Int`
* `error: OpenWorkFetchError?`

Staleness is derived: `error != nil && !allItems.isEmpty`. A first-run failure is `.idle` with `error`, not stale data. The store hydrates `lastSuccess`, `matchedCount`, `fetchedCount` and `truncated` from `dispatch.openWorkLastRun` in `init` for display only. `updatedCount` is 0 on the first fetch of a launch; on later fetches it counts items newer than the previous `lastSuccess`. It is not persisted.

**`OpenWorkLastRunSummary`** is `Codable, Sendable`: `lastSuccess: Date?`, `matchedCount: Int`, `fetchedCount: Int`, `truncated: Bool`. It is JSON-encoded under `dispatch.openWorkLastRun`. A decode failure is treated as “no summary,” not as snapshot corruption.

### Fetch

`GitHubService.fetchOpenWork()` performs one search and owns its pagination. The query is built with `URLComponents`:

```text
path: search/issues
q:    is:open involves:@me
sort: updated
order: desc
per_page: 100
```

Rules:

* Request page 1, read `total_count` into `matchedCount`, and follow the `Link: rel="next"` header up to four pages. Stop when no next link exists.
* Reuse `validate` and `nextPageURL`; do not use the permissive `requestAllPages` helper.
* Any non-2xx on any page throws `OpenWorkFetchError`. A 404 is not an empty success.
* Deduplicate by `key` across pages, keeping the first occurrence in page order. Search pagination can shift while the user works, so a duplicate is expected.
* Set `truncated` when `matchedCount > 400` or when page four advertises a next link. Do not derive it from the deduplicated item count or a short page.
* Set `complete` when `!truncated`, the loop ended with no next link, and no error occurred.
* Keep `OpenWorkSearchResponse` and add `total_count: Int`; keep `OpenWorkUserPayload`, which `OpenWorkIssuePayload` uses for `user` and `assignees`.
* Map `OpenWorkIssuePayload` to `OpenWorkItem` with `mapOpenWorkItem(_:) -> OpenWorkItem?`: skip when `repositoryName(from:)` or `URL(string: html_url)` fails; `authorLogin = user?.login ?? "ghost"`; parse `updated_at` with a fractional-seconds ISO-8601 formatter, then a plain formatter, then `Date()`; `key = "\(repository.lowercased())#\(number)"`; kind from `pull_request != nil`.
* Map every `GitHubError`, `AuthError` and `URLError` to `OpenWorkFetchError`: `missingToken` and `AuthError.keychainError`/`decodingFailed` → `notConfigured`, `invalidURL` and `URLError` → `transport`, 401 → `unauthorized`, 403 → `forbidden(resetAt:)`, 404 → `notFound`, 5xx and other non-2xx → `server`, decode failures → `decoding`.

### Refresh and failure

`OpenWorkStore` owns the refresh clock and the fetch.

* `lastAttempt`, `hasFetchedThisLaunch` and `hasOpenedOpenWork` are store fields. At attempt start, capture `isFirstFetch = !hasFetchedThisLaunch`, then set `lastAttempt = now()` and `hasFetchedThisLaunch = true`, independent of outcome.
* `noteWorkspaceOpened() async` sets `hasOpenedOpenWork = true` and awaits `refreshIfDue()`. `OpenWorkView.task` awaits it.
* `refreshIfDue()` refreshes when `isConfigured`, `hasOpenedOpenWork`, no refresh is in flight, and either `!hasFetchedThisLaunch` or `now().timeIntervalSince(lastAttempt) >= 900`.
* `refresh()` sets `.running`, clears `error`, awaits `fetchAction`, and applies the result. It stores `refreshTask`; a second caller awaits the same task instead of starting a request. The task is cleared in `defer`.
* `applySuccess(result, isFirstFetch:)` always replaces `allItems`, sets `phase = .ready`, clears `error`, and updates `matchedCount`, `fetchedCount` and `truncated`. It captures `previousIndex` from the old flattened `groups` before replacement, computes `updatedCount` from the previous `lastSuccess` (0 when `isFirstFetch`), then sets `lastSuccess = now()`. If `selectedKey` disappeared, select `visibleCount == 0 ? nil : min(previousIndex, visibleCount - 1)`. If `canPrune` (`result.complete`), it prunes hidden keys absent from the result; otherwise it keeps every hidden key.
* On failure, keep `allItems`, `selectedKey`, `lastSuccess`, `matchedCount`, `fetchedCount`, `truncated` and `updatedCount`; set `error`; set `.ready` if items exist, otherwise `.idle`.
* `clear()` cancels `refreshTask`, clears `allItems`, status, selection, `lastHiddenKey`, the last-run summary and `isConfigured`, and keeps `hiddenKeys`. A result that completes after `clear()` is discarded because `isConfigured` is false and the refresh generation no longer matches.
* `SyncCoordinator` owns the trigger, not the clock: the existing 45-second loop calls `openWorkStore.refreshIfDue()`; `handleSystemDidWake()` calls `performSyncCycle()` and then `refreshIfDue()`. There is no attempt timestamp in the coordinator.

### Store behavior

`OpenWorkStore` is `@MainActor` and `@Observable`.

* `init(fetchAction:isConfigured:defaults:now:)` takes the fetch closure, the initial connection state, an injected `UserDefaults`, and a `@Sendable () -> Date` clock.
* `allItems` is the source of truth; `hiddenKeys: Set<String>` is unbounded and stores lowercased keys. `visibleItems` is `allItems` minus hidden keys; `groups` is built from `visibleItems`; `visibleCount` and `hiddenCount` are derived and cached on every mutation, not recomputed per row render.
* `groups` sorts repositories by their newest item's `updatedAt` descending, tie-breaks by repository name, and sorts items inside a group by `updatedAt` descending.
* `selectedItem` is the item for `selectedKey`; `selectedKey` is preserved across refreshes. If it disappears, select `visibleCount == 0 ? nil : min(previousIndex, visibleCount - 1)` in the flattened `groups` order. Hiding the selected item selects the next visible item.
* `hide(key:)` inserts the key, records `lastHiddenKey`, sets `undoDeadline = now() + 6`, persists the set, and starts a 6-second action banner. `unhide(key:)` restores one item. `clearAllHidden()` removes every hidden key. `dismissUndoBanner()` clears `lastHiddenKey`. `lastHiddenKey` survives refreshes and is cleared only by `undoDeadline` expiry, `dismissUndoBanner()`, or the next hide. `canUndo` is true while `undoDeadline > now()`. `Cmd+Z` calls `unhide(lastHiddenKey:)` while `canUndo`.
* `hiddenCount` counts keys present in `allItems`, not every persisted key. The “Clear all hidden keys” action removes every persisted key; its count may be lower than the number removed, and the menu says so in its help text.
* `updatedCount` is 0 on the first fetch of a launch; on later fetches it counts items newer than the previous `lastSuccess`. All reads and writes of counts go through `status`.
* `isConfigured` is set from the Keychain at launch and by Settings on validation or clear.

### View states

One table drives the header, body, banner and action. Disconnected overrides every other row.

| Condition | Header | Body / banner | Action |
| --- | --- | --- | --- |
| `!isConfigured` | “GitHub isn’t connected” | “Connect a GitHub token in Settings.” | “Open Settings” |
| `.running` and no items | “Loading Open Work…” | previous data stays if present | Refresh disabled, label “Refreshing…” |
| `.running` with items | previous counts | rows stay | Refresh disabled, label “Refreshing…” |
| `.idle`, no items, no summary, no error | “Not loaded this session” | “Open Work has not loaded this session.” | Refresh |
| `.idle`, no items, no summary, error | “Not loaded this session” | “Could not load Open Work: <reason>.” | error action |
| `.idle`, no items, with summary, no error | “Not loaded this session · last successful refresh X ago · M matched” | “Open Work has not loaded this session.” | Refresh |
| `.idle`, no items, with summary, error | “Not loaded this session · last successful refresh X ago · M matched” | “Could not load Open Work: <reason>.” | Refresh and the error action |
| `.ready`, no items | “0 visible · 0 hidden · 0 matched” | “No open issues or pull requests involve you.” | Refresh |
| `.ready`, all items hidden | “0 visible · H hidden · M matched” | “All H items are hidden.” | “Clear all hidden keys” |
| `.ready`, items, `error != nil` | counts + “last successful refresh X ago” | stale banner with the error action; rows stay | error action and Refresh |
| `.ready`, items, no error | counts + “U updated · last successful refresh X ago” | rows | Refresh |

The sidebar shows `visibleCount` in a neutral capsule labelled “N open items” only when `status.phase == .ready || !allItems.isEmpty` and at least one item is visible. Otherwise it shows “—”.

Error actions, one per `OpenWorkFetchError` case:

| Error | Copy | Action |
| --- | --- | --- |
| `notConfigured` | “GitHub isn’t connected.” | Open Settings |
| `unauthorized` | “GitHub rejected the token.” | Update token (Settings) |
| `forbidden(resetAt:)` | “GitHub rate limit reached.” | “Retry at HH:MM,” disabled until then and re-enabled by a one-minute timeline; if `resetAt` is nil, Update token |
| `notFound` | “Open Work endpoint not found.” | Retry |
| `server` | “GitHub server error.” | Retry |
| `decoding` | “GitHub returned an unexpected response.” | Retry |
| `transport` | “Network unavailable.” | Retry |

### Views

* `MainSplitView` chooses `TriageStreamView` for Gmail and `OpenWorkView` for GitHub. `activeWorkspace` remains on `TriageStore`; the views read it, and the stores never read each other.
* `SidebarView` keeps Gmail unread counts. The GitHub row follows the sidebar rule above. The GitHub filter section is removed. The bottom “Live” indicator and `TriageStore.isLoading` are removed; the settings gear stays.
* `OpenWorkView` (reads `OpenWorkStore`, `PreferencesStore` for `@login`, and `@Environment(\.openSettings)`):
  * `.task { openWorkStore.noteWorkspaceOpened() }`.
  * Header line 1: “V visible · H hidden · M matched”.
  * Header line 2: “U updated · last successful refresh X ago” with the Refresh button; the button reads “Refreshing…” and is disabled while running.
  * Truncation line, when `truncated`: “F fetched of M matched (400-item cap; GitHub reports at most 1,000)”.
  * Info popover: “Open work involving @login that this token can read: authored, assigned, mentioned, or commented on. Review requests and subscriptions are not included.”
  * The state table above supplies every banner and empty state.
  * Repository sections show a visible count per section.
  * Row: title, repository `#number`, author, relative update time, issue or PR marker. Accessibility labels use the absolute date.
  * Hidden action: “Clear all hidden keys” in the header menu. No per-item restore and no hidden-items sheet in v1.
  * The 6-second hide/undo banner.
* `DetailPaneView` gets an Open Work branch that reads `openWorkStore.selectedItem` when GitHub is active and accepts `OpenWorkItem`. Use `store.githubService` for `fetchIssueDetails`; a detail 401/403 renders inline without changing the list. Replace Archive/Trash with “Open on GitHub” and “Hide from Open Work”. `⌘⇧A` calls `OpenWorkDispatcher.makePayload`; a detail fetch failure shows “Send title only / Cancel.”
* Keyboard routing follows `activeWorkspace`: `j`/`k` navigate the active store and stop at the ends; `e` hides in Open Work; `u`, `s` and `#` show “Not available in Open Work” and do nothing; `Cmd+O` opens the selected item on GitHub; `Cmd+Shift+A` dispatches; `Cmd+Z` undoes the last hide while the banner is alive. Gmail shortcuts are unchanged. A shortcut legend in the header menu labels `e` as “Hide from Open Work”.
* Settings shows the connected or disconnected GitHub state, the token field with Validate & Save, Clear PAT, and the read-only scope sentence. It does not duplicate the Open Work status line.
* Onboarding renames the GitHub card to “GitHub Open Work” and reads `preferencesStore.isGitHubConfigured`.

### Dispatch

`OpenWorkDispatcher` in `Sources/DispatchApp/Services/OpenWorkDispatcher.swift` owns two functions: `makePayload(item:detail:)` builds `AgentDispatchPayload`, and `makeTitleOnlyPayload(item:)` builds the same payload with an empty body and comments. `MainSplitView.dispatchCurrentItem()` branches on `activeWorkspace`: Gmail keeps the existing refusal; GitHub uses the Open Work item. The detail pane’s button calls the same builder with its loaded detail.

If detail is not loaded, the view fetches it. On failure, show an alert with “Send title only” and “Cancel”; the first calls `makeTitleOnlyPayload`. `performDispatch(payload:preferences:)` calls `AgentDispatchService.dispatch`. That service must copy the prompt and return without opening a terminal when `AgentCLI.none` (Clipboard Only) is selected. If the terminal is unavailable (`NSWorkspace.shared.urlForApplication(withBundleIdentifier:) == nil`), the action is disabled with “Configure a terminal in Settings.”

### PAT storage

The PAT is stored only in the macOS Keychain. `PreferencesStore` loses `githubPAT` and its `dispatch.githubPAT` UserDefaults key. `DispatchApp`'s token provider reads the Keychain only.

`LegacyStateMigrator.run(defaults:)` runs in `DispatchApp.init` before the store is constructed. It uses synchronous Keychain helpers on `AuthService` (`migrateGitHubPAT`, `hasGitHubPAT`) and `SnapshotData.load(from:)` for the old snapshot:

1. If `dispatch.githubPAT` exists, copy it to the Keychain with `SecItemAdd`/`SecItemUpdate` and verify with `SecItemCopyMatching`. On failure, keep the defaults value only for manual recovery, set `isConfigured` false, and show “reconnect required.” The token provider is Keychain-only; there is no two-source provider.
2. Union `dispatch.openWorkHiddenKeys` with the migrated keys from `SnapshotData.dismissedGitHubKeys` and `dispatch.dismissedGitHubIssueIDs`. Strip `gh:issue:`, `gh:pr:` and `gh:` longest-first, lowercase, drop `gh:thread:` keys, and deduplicate.
3. Delete the old defaults keys only after the seed and the Keychain copy succeed.
4. Take `isConfigured` from the migration result (or `AuthService.hasGitHubPAT()` when no defaults PAT exists), pass it into `OpenWorkStore.init(fetchAction:isConfigured:defaults:now:)`, and set `PreferencesStore.isGitHubConfigured` before the first view body.

Settings and onboarding read `preferencesStore.isGitHubConfigured`; no async Keychain read per view. “Clear PAT” confirms, deletes the Keychain value, sets both `isConfigured` flags false, and calls `openWorkStore.clear()`; hidden keys stay. Validating a PAT saves it, sets both flags true, and calls `refresh()`.

### Removals and compatibility

* Remove `TriageStore.gitHubItems`, `gitHubFilter`, `filteredGitHubItems`, `setGitHubBackfill`, `mergedGitHubItems`, `dismissBackfillItemLocally`, `dismissLocally`, `dismissedGitHubKeys` and `dismissedGitHubIssueIDs`. Keep `activeWorkspace`, `githubService` and `TriageSource.gitHub`. `activeItems` returns an empty GitHub fallback; `setItems(_:for: .gitHub)` is a no-op; `unreadCount(for: .gitHub)` returns 0; `selectedItem` is Gmail-only.
* Remove `TriageItem.isBackfillDerived`, the GitHub cases from `TriageKind`, `ReviewStatus`, `CheckSuiteStatus`, and `canonicalKey`. Only Gmail uses `TriageItem` afterwards.
* Remove `GitHubService.fetchAssignedIssues`, `fetchOpenIssuesAndPullRequests`, `normalizeRepositories`, `normalizeOwners`, `decodeOpenWork`, `decodeSearchOpenWork`, `mapOpenWork`, `requestAllPages`, `dismissNotification`, `unsubscribeNotification` and `fetchCheckRuns`. Keep `nextPageURL`, `validate`, `OpenWorkIssuePayload`, `OpenWorkUserPayload`, `OpenWorkSearchResponse` (with `total_count`), `mapOpenWorkItem` and `fetchIssueDetails`.
* Remove `GitHubFilter`, the sidebar filter section, and the filter counts.
* Remove `PreferencesStore.trackedRepositories`, `trackedOwners`, their keys, `normalizedTrackedRepositories`, `normalizedTrackedOwners`, `githubPAT`, and the `dispatchGitHubBackfillRequested` notification.
* Keep `SnapshotData.gitHubItems` and `dismissedGitHubKeys` in the file format. Use the Slice 3 `SnapshotData.init(from:)` and `load(from:)`; remove both `loadSnapshot` assignments to `gitHubItems` and `dismissedGitHubKeys`. Save `gitHubItems: []` and `dismissedGitHubKeys: nil`.
* On a Gmail snapshot decode failure, rename the file to `snapshot.corrupt-<ISO8601>.json`, log once, start with empty Gmail state, and allow the next save. Do not suppress saving forever.
* Update `SyncCoordinator.getStatus()` to drop `lastGitHubETag`.

### Rate limits and bounds

* Worst case is 4 requests per refresh at 15-minute intervals: 16 requests per hour against the 30-per-minute search limit.
* A typical user with fewer than 100 matches costs one request per refresh.
* There is no per-repository fan-out, so request count does not grow with repository count.
* The 400-item cap is disclosed, not hidden. GitHub caps `total_count` at 1,000, so the largest displayable match count is 1,000.

### Concurrency

* `GitHubService` remains a stateless `Sendable` class; its concurrency model is unchanged.
* `OpenWorkStore` is `@MainActor @Observable`. `fetchAction` is `@Sendable () async throws -> OpenWorkFetchResult` and is an initializer parameter.
* `SyncCoordinator` remains an actor. Its refresh closure is `@MainActor @Sendable () async -> Void` and calls `openWorkStore.refreshIfDue()`.
* No intermediate update payload crosses an actor boundary; the store awaits the fetch and applies the result on the main actor.

--------------------------------------------------------------------------------

## Alternatives Considered

### Alternative A: Keep the merged feed and add a status row

* **Pros**: Smallest code change. One list, one selection model, and the existing tests keep working.
* **Cons**: The live assigned feed re-marks items unread every 45 seconds (`GitHubService.swift:195`, `SyncCoordinator.swift:281-291`), so imported work cannot stay out of the unread count while both feeds share `gitHubItems`. The 500-item cap and dismissal pruning still apply to the merged array.
* **Reason for Rejection**: It cannot satisfy the core invariant that imported work is never unread, and it leaves the partial-failure data loss intact.

### Alternative A2: Delete the live feed, keep the existing list, add status

* **Pros**: Smaller diff than a new store and view. One selection model. No second item type at the view layer.
* **Cons**: `TriageStore` selection and navigation are `TriageItem`-typed (`TriageStore.swift:276-300`), and `TriageItem` is persisted in the Gmail snapshot. Widening it to carry Open Work reopens the snapshot migration and source-switch complexity. Repository grouping and an independent selection still need new state.
* **Reason for Rejection**: The separate store costs less than widening the persisted type and its merge paths. The Gmail snapshot stays untouched.

### Alternative B: Add an Open Work filter or tab to the existing list

* **Pros**: No new store or selection model. Users keep one screen.
* **Cons**: The underlying array is still ordered by merge position, not by repository or update time. The 500-item cap still truncates by position, provenance still depends on an ID prefix, and both dismissal stores remain.
* **Reason for Rejection**: It changes what is visible without changing the state model that produces the bugs.

### Alternative C: Persist imported items in the existing snapshot

* **Pros**: Instant display on cold start, and hiding plus last-success status survive relaunch.
* **Cons**: `SnapshotData` has no schema version and its decoder clears the cache on a model mismatch (`TriageStore.swift:309-327`). Adding item persistence requires a versioned format, a migration path, and a strategy for stale data at launch. It also stores a second copy of data that GitHub already owns.
* **Reason for Deferral**: Deferred, not dismissed. The first version is in memory, which removes the migration risk. Persistence can be added behind a schema version once cold-start demand is demonstrated. A last-run summary is persisted so the header is not blank.

### Alternative D: One-time import with a manual refresh

* **Pros**: Minimal network use and the simplest possible scheduling. No periodic housekeeping.
* **Cons**: Closed and merged items linger forever unless the user remembers to refresh. The view cannot honestly claim the list is current. A one-time import also makes “Backfill Now” mean “replace my snapshot”, which needs different copy and a confirmation.
* **Reason for Rejection**: A full refresh costs one request for a typical user and at most four, so the 15-minute cadence is cheap. The user also chose periodic refresh over a one-time import.

### Alternative E: Enumerate every repository the token can read

* **Pros**: Truly every open issue and pull request in the accessible set, independent of GitHub's involvement semantics.
* **Cons**: It imports other people's backlog. Request count scales with repository count rather than with the user's work. It also multiplies the ways a partial fetch can fail.
* **Reason for Rejection**: The goal is the user's work, not every repository's open issues. The involvement query matches the intent and keeps the request count bounded.

### Alternative F: Use the GitHub notifications endpoint as the source

* **Pros**: GitHub supplies the reason for each notification (`mention`, `review_requested`, `ci_activity`), and read state already exists server-side.
* **Cons**: `/notifications` returns unread threads, not all open work. It requires a classic token with the notifications scope, which conflicts with the fine-grained token path. It also reintroduces the merge between notifications and open work that this design removes.
* **Reason for Rejection**: It answers “what changed” rather than “what is open”. The two questions need different sources and different views.

### Alternative G: GraphQL search instead of REST

* **Pros**: One query can return `totalCount`, page info and only the needed fields. It avoids over-fetching.
* **Cons**: Fine-grained token support and SSO authorization must be verified before relying on it. It adds a second protocol, a second error surface, and a second authentication path to a small application. The REST search endpoint already returns `total_count` and works with the classic token the product documents.
* **Reason for Rejection**: REST covers the requirements for this version. Revisit GraphQL only if pagination or the 1,000-result ceiling becomes a demonstrated limit.

### Alternative H: Remove the feature and rely on GitHub saved views

* **Pros**: No code, no polling, no new state. GitHub already filters open work by involvement, assignment and review request.
* **Cons**: It gives up the local detail view, the `⌘⇧A` agent dispatch path, and the single-window Gmail plus GitHub workflow. It also contradicts the stated goal of keeping existing work inside Dispatch.
* **Reason for Rejection**: Open Work does one job better than `github.com/issues`: it keeps the user's GitHub work in the same window as Gmail, grouped by repository, with local hide and `⌘⇧A` dispatch. The fallback remains if that job does not matter to the user.

--------------------------------------------------------------------------------

## Non-Functional Requirements

**Security and privacy.** The PAT is stored only in the macOS Keychain; the UserDefaults copy is migrated and deleted. The only new network call is the GitHub search endpoint, already reached through `GitHubService`. No token is written to logs. Hidden-item keys are repository names and numbers, not message content. The last-run summary contains counts and timestamps only. The snapshot decoder must not log snapshot contents.

**Performance and cost.** A refresh costs one request for a user below 100 matches and at most four requests at the 400-item cap. At a 15-minute interval that is 16 requests per hour against the 30-per-minute search limit. The store holds at most 400 value types and one hidden-key set in memory. Groups are cached on mutation, not recomputed per row render. No new background CPU runs while the app sleeps.

**Rollout and rollback.** There is no server change. Old snapshots decode because `gitHubItems` is read with `try?` and written as `[]`. A corrupt snapshot is renamed to `snapshot.corrupt-<date>.json` and the app starts clean. Reverting the release leaves the new UserDefaults keys unused; the old snapshot still loads because `gitHubItems` remains a valid, empty array. The PAT migration copies before deleting. A failed Keychain write leaves the defaults value for manual recovery and shows reconnect required; the provider remains Keychain-only.

**Compatibility.** macOS 14 and later. Classic PATs work. Fine-grained PATs and SSO-protected organizations may return a smaller set; explicit support is a documented v1 limitation, not a promise. The view states that the scope is what the token can read.

**Accessibility.** The header, stale banner and truncation banner are text, not color alone. Repository sections carry headings. Rows expose labels with title, kind, `repo#number`, author and an absolute date; the visible row shows a relative time. The sidebar capsule is labelled “N open items”. Hiding shows an action banner reachable by keyboard and announces through an accessibility notification; a refresh reports removals through a live-region announcement. Focus follows the selected row after a user-initiated hide, not after a background refresh. The Refresh control has a label and a “Refreshing…” state.

### Risks and Mitigations

* **Scope loss.** Subscription-only and review-requested items are excluded, and relationship reasons are not shown. Mitigation: state the limits in the view and README; record them as future work.
* **Revoked or expired PAT.** Every refresh fails with the same 401. Mitigation: show “Update token” with a Settings action; retain the 15-minute attempt cadence.
* **Hidden-item resurrection.** A truncated refresh does not prune hidden keys. A repository rename or transfer changes `owner/repo#number`, so a hide can be lost. Mitigation: prune only on complete runs; state the rename limitation; key on the numeric issue id in a future version.
* **Corrupt snapshot.** Mitigation: quarantine the file once and start clean; the corrupt copy remains on disk.
* **Cold start.** The list is empty until the first fetch. Mitigation: persist the last-run summary and show it while fetching; never claim the data is current.
* **Per-item restore.** Only bulk clear exists in v1. Mitigation: document it; add a hidden-items sheet in a future version.

### Additional Resources

* `../../concepts_brief_backfill.md` — brainstorm brief, Goldfish findings and the alternatives weighed before drafting.
* `../../design_draft.md` — original application design. This document replaces its GitHub backfill section; the Gmail and agent-dispatch sections remain in force.

### Future Improvements

* **Hidden-items sheet:** List hidden keys with title and hide time, with per-item restore. The current version offers undo plus clear-all.
* **Relationship data:** Add Assigned, Authored and Mentioned grouping once evidence shows users need to know why each item matched.
* **Stable hidden keys:** Key hides on GitHub's numeric issue id so repository renames and transfers do not resurrect them.
* **Persistence:** Add a versioned Open Work snapshot and a migration path if cold-start demand is proven.
* **Large result sets:** If users routinely exceed 400 matches, add a narrower default scope or explicit paging beyond the cap.
* **Repository-level hide:** If watch noise becomes a problem, add a way to hide a repository instead of individual items.
* **CI status and merge:** A separate follow-up design. List-wide CI requires per-pull-request detail and check-run requests, or a GraphQL query, and merge requires write permission, a confirmation flow, and branch-protection error handling.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

The work is ordered into five slices. Each slice must compile and pass the full test suite before the next starts. No slice leaves the tree in a state where a removed symbol still has a caller. Slice 3 lands the root construction, the migration, and the Settings/Onboarding Keychain checks together. Slice 4 adds the views while the old GitHub cases still exist. Slice 5 removes the old paths and the dead view branches together.

### Slice 1: Models, fetch and fetch tests

#### 1. `Sources/DispatchApp/Models/OpenWorkItem.swift` (Create)

* **Type / Scope**: Model type.
* **Proposed Changes**: Add `OpenWorkItem` (`Identifiable`, `Hashable`, `Sendable`), `OpenWorkItemKind` (`.issue`, `.pullRequest`, `Hashable`, `Sendable`), `OpenWorkGroup` (`repository`, `items`, `visibleCount`), `OpenWorkFetchResult` (`Sendable`), `OpenWorkFetchError` (`Error`, `Sendable`), `OpenWorkStatus` (`Sendable`) and `OpenWorkLastRunSummary` (`Codable`, `Sendable`). `OpenWorkItem.key` is `owner/repo#number` lowercased; `repository` preserves display case. All new types are `public` to match the codebase; `mapOpenWorkItem` is `internal` so tests can call it.

#### 2. `Sources/DispatchApp/Services/GitHubService.swift` (Modify)

* **Type / Scope**: Network service.
* **Proposed Changes**: Add `fetchOpenWork() async throws -> OpenWorkFetchResult`. Build the query with `URLComponents` (`q=is:open involves:@me`, `sort=updated`, `order=desc`, `per_page=100`), own the page loop, read page one's `total_count`, follow `Link: rel="next"` up to four pages, deduplicate by `key`, and set `truncated` and `complete` as defined in the Technical Plan. Reuse `validate` and `nextPageURL`; do not use `requestAllPages`. Add `mapOpenWorkItem(_:) -> OpenWorkItem?` with the skip/fallback rules. Any non-2xx throws `OpenWorkFetchError`. Keep `OpenWorkSearchResponse` and add `total_count: Int`; make `OpenWorkUserPayload`, `OpenWorkIssuePayload` and `OpenWorkSearchResponse` `internal` so the mapper can be tested. Keep every existing method until the slice that removes its caller. Remove only `fetchCheckRuns`, which is already unused. Map `GitHubError`, `AuthError` and `URLError` to `OpenWorkFetchError` inside `fetchOpenWork`; the store never sees the underlying types.

#### 3. `Tests/DispatchAppTests/OpenWorkFetchTests.swift` (Create)

* **Type / Scope**: Service tests with the shared `MockURLProtocol` in `SyncCoordinatorTests.swift`.
* **Proposed Changes**: Cover one-page and multi-page responses, `total_count` mapping, the four-page cap, duplicates across pages, a short last page, a page-two 404, 401, 403 with reset, 5xx, malformed JSON, missing token, and the `URLComponents` contract (path and query items). Add a request recorder to the shared `MockURLProtocol` and assert it records only search requests. Assert a 404 throws and never becomes an empty success, exactly 400 results are complete, and the internal `mapOpenWorkItem` handles nil author/URL through JSON fixtures.

### Slice 2: Store and store tests

#### 4. `Sources/DispatchApp/State/OpenWorkStore.swift` (Create)

* **Type / Scope**: Main-actor observable store.
* **Proposed Changes**: `init(fetchAction:isConfigured:defaults:now:)`. Hold `allItems`, `hiddenKeys`, `lastHiddenKey`, `undoDeadline`, `bannerTask`, `status`, `selectedKey`, cached `[OpenWorkGroup]`, `lastAttempt`, `hasFetchedThisLaunch`, `hasOpenedOpenWork`, `isConfigured`, `refreshGeneration` and `refreshTask: Task<Void, Never>?`. Implement `applySuccess(_:isFirstFetch:)`, `refresh`, `refreshIfDue() async`, `noteWorkspaceOpened() async`, `hide`, `unhide`, `clearAllHidden`, `dismissUndoBanner`, `clear`, `selectNext` and `selectPrevious`. Compute `visibleItems` from `allItems` minus hidden keys, and `groups` from `visibleItems`; capture the old flattened index before replacement. `clear()` keeps hidden keys, cancels `refreshTask`, and increments `refreshGeneration`; a completing fetch applies only if `isConfigured` is true and its generation matches. In `defer`, clear `refreshTask` only if it is still the current task.

#### 5. `Tests/DispatchAppTests/OpenWorkStoreTests.swift` (Create)

* **Type / Scope**: Store tests.
* **Proposed Changes**: Cover success that updates the summary, truncated success that still updates the summary but does not prune, failure retaining items and the summary, first-fetch-of-launch, one refresh per due interval, failed-attempt throttling, single-flight refresh, selection fallback including the empty visible list, newest-first grouping, hide/unhide/undo, hide → refresh → undo, undo after expiry, hidden-key persistence, all-hidden state, `clear()` keeping hides and cancelling the task, the generation guard, and the `updatedCount` calculation.

### Slice 3: Coordinator, composition, migration, Settings and tests

#### 6. `Sources/DispatchApp/Services/SyncCoordinator.swift` and `Sources/DispatchApp/Services/GitHubService.swift` (Modify)

* **Type / Scope**: Actor, due trigger, and service removals.
* **Proposed Changes**: Before removing any service method, delete `Tests/DispatchAppTests/GitHubBackfillTests.swift` and update `SyncCoordinatorTests` (item 9). `SyncCoordinator` becomes `init(gmailService:refreshOpenWork:)`; remove `gitHubService` unconditionally, all backfill properties and methods, the `start()` call to `backfillGitHubIfNeeded()`, `refreshBackfillIfDue()`, `pollCycleCount`, `lastGitHubETag`, and `syncGitHub`. Add a `@MainActor @Sendable () async -> Void` refresh closure. The existing 45-second loop calls it; `handleSystemDidWake()` calls `performSyncCycle()` and then the closure. `performSyncCycle` becomes Gmail-only. Update `getStatus()` to drop `lastGitHubETag`. In `GitHubService`, remove `fetchAssignedIssues`, `fetchOpenIssuesAndPullRequests`, `decodeOpenWork`, `decodeSearchOpenWork`, `mapOpenWork`, `requestAllPages`, `deduplicated` and `newestFirst` once their callers are gone. Keep `normalizeRepositories` and `normalizeOwners` until `PreferencesStore` stops calling them in Slice 5; keep `nextPageURL`, `validate`, `repositoryName` and the paging helpers used by `fetchOpenWork`.

#### 7. `Sources/DispatchApp/App/DispatchApp.swift` and `Sources/DispatchApp/Services/AuthService.swift` (Modify)

* **Type / Scope**: Composition root and Keychain presence check.
* **Proposed Changes**: Add `PreferencesStore.isGitHubConfigured` (`public var`, not persisted) in this slice. Add `SnapshotData.init(from:)`, `static func load(from:) throws -> SnapshotData` and `static var defaultSnapshotURL: URL` in `TriageStore.swift` in this slice. Add nonisolated static synchronous Keychain helpers to `AuthService`: `hasGitHubPAT() -> Bool` and `migrateGitHubPAT(defaults:) -> Bool`, using `SecItemCopyMatching`/`SecItemAdd`/`SecItemUpdate`. Extract `LegacyStateMigrator.run(defaults:keychain:snapshotURL:) -> MigrationResult` into `Sources/DispatchApp/State/LegacyStateMigrator.swift`, with an injectable `KeychainStoring` seam and an injected snapshot URL; it copies/verifies the PAT, unions the old hidden keys into `dispatch.openWorkHiddenKeys`, deletes old keys only after success, and returns `isConfigured` and `needsReconnect`. In `DispatchApp.init`, construct `AuthService`; run the migrator; construct `GitHubService` with a Keychain-only token provider; if migration failed, set `isConfigured = false` and show reconnect required (no defaults provider). Construct the Gmail/GitHub services and `OpenWorkStore(fetchAction:isConfigured:defaults:now:)`; then `SyncCoordinator(gmailService:refreshOpenWork:)`. Add `.environment(openWorkStore)` to both the `WindowGroup` and `Settings` scenes. `setupServicesAndSync()` uses `@State private var hasStarted = false`; it wires callbacks, keeps `triageStore.githubService = gitHubService`, loads the Gmail snapshot, and starts the coordinator on the first window only. Remove the `dispatchGitHubBackfillRequested` listener, `setBackfillConfiguration` and `setOnBackfillUpdated`.

#### 8. `Tests/DispatchAppTests/OpenWorkCoordinatorTests.swift` (Create)

* **Type / Scope**: Due-trigger tests.
* **Proposed Changes**: Assert the coordinator’s 45-second loop and wake handler call the refresh closure, that a second window does not start a second coordinator, and that a manual refresh does not overlap. The due-interval and first-fetch assertions belong to `OpenWorkStoreTests`, which has the injected clock and calls `noteWorkspaceOpened()` directly.

#### 9. `Tests/DispatchAppTests/SyncCoordinatorTests.swift` (Modify)

* **Type / Scope**: Coordinator tests.
* **Proposed Changes**: Remove the GitHub assigned-issue and ETag tests, including `testColdBootstrapSync`'s `lastGitHubETag` assertion and `ghCount` block. Replace the remaining two-argument `SyncCoordinator(gmailService:gitHubService:)` constructions with `init(gmailService:refreshOpenWork:)`. Keep Gmail bootstrap, history, sleep/wake and network tests. Keep the shared `MockURLProtocol` and its new request recorder here.

#### 10. `Sources/DispatchApp/Views/SettingsView.swift` (Modify)

* **Type / Scope**: Preferences UI.
* **Proposed Changes**: Remove the “Open Work Backfill” section, both text fields, their bindings, the Backfill Now button, and the notification post in `validateGitHubPAT`. Keep the GitHub PAT field and Validate & Save; remove the `tempGitHubPAT = preferencesStore.githubPAT` prefill. Remove every remaining `preferencesStore.githubPAT` read/write, including the Clear PAT guard and the validation assignment; guard Clear PAT on `preferencesStore.isGitHubConfigured` and keep the `githubUsername` assignment from validation. Render connected state from `preferencesStore.isGitHubConfigured`. Add a “Clear PAT” action with confirmation: delete the Keychain value, set both `isConfigured` flags false, call `openWorkStore.clear()`, and keep hidden keys. Add a read-only scope sentence. Change the PAT copy to `repo` only and remove `notifications`. Validation saves to the Keychain, sets both flags true, and calls `openWorkStore.refresh()`.

#### 11. `Sources/DispatchApp/Views/OnboardingView.swift` (Modify)

* **Type / Scope**: First-run copy.
* **Proposed Changes**: Rename the GitHub card to “GitHub Open Work” and describe the involvement scope. `isConnected` reads `preferencesStore.isGitHubConfigured`; no async Keychain read. No new flow.

### Slice 4: Views, routing and documentation

The views switch to Open Work while the old GitHub cases still exist, so this slice compiles before anything is deleted. Slice 5 removes the dead branches with the cases.

#### 12. `Sources/DispatchApp/Views/MainSplitView.swift` (Modify)

* **Type / Scope**: Layout and keyboard routing.
* **Proposed Changes**: Choose `TriageStreamView` for Gmail and `OpenWorkView` for GitHub. Route `j`/`k`, `e`, `Cmd+O`, `Cmd+Shift+A`, `Cmd+Z`, `u`, `s` and `#` through the active workspace. `e` calls `openWorkStore.hide(key:)`; `u`, `s` and `#` show “Not available in Open Work”. Add a `Cmd+Z` receiver guarded by `openWorkStore.canUndo`. Replace `isFirstLaunchEmptyState` with `preferencesStore.googleClientId.trimmingCharacters(...).isEmpty && !preferencesStore.isGitHubConfigured && store.gmailItems.isEmpty`, not item count. Do not call the coordinator; `OpenWorkView.task` awaits `noteWorkspaceOpened()`. Branch `dispatchCurrentItem()` on `activeWorkspace`: Gmail keeps the existing refusal; GitHub calls `OpenWorkDispatcher.makePayload` and `performDispatch`. Leave the GitHub `TriageKind` cases in place until item 20. Also create `Sources/DispatchApp/Services/OpenWorkDispatcher.swift` with `static func makePayload(item: OpenWorkItem, detail: GitHubIssueDetail?) -> AgentDispatchPayload`, `static func makeTitleOnlyPayload(item: OpenWorkItem) -> AgentDispatchPayload`, and `static func performDispatch(payload: AgentDispatchPayload, preferences: PreferencesStore) async throws`. Also modify `Sources/DispatchApp/Services/AgentDispatchService.swift` so `AgentCLI.none` copies the prompt and returns without opening a terminal, and the terminal-availability check uses `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`.

#### 13. `Sources/DispatchApp/Views/OpenWorkView.swift` (Create)

* **Type / Scope**: New primary view.
* **Proposed Changes**: Create `Sources/DispatchApp/Models/OpenWorkPresentation.swift` and `Tests/DispatchAppTests/OpenWorkViewStateTests.swift` in this slice. `OpenWorkPresentation.init(status: OpenWorkStatus, visibleCount: Int, hiddenCount: Int, hasSummary: Bool, now: Date)` produces `headerText`, `secondaryText`, `truncationText`, `emptyText`, `bannerText`, `sidebarText` and `action: (label: String, kind: OpenWorkAction, isEnabled: Bool)`. `OpenWorkAction` is `.openSettings`, `.updateToken`, `.retry(until: Date?)`, `.refresh`, `.clearHidden`. Render the header, truncation line, info popover, state table, repository sections, rows, Refresh button, “Clear all hidden keys” menu and the 6-second hide/undo banner from it. Add `.task { await openWorkStore.noteWorkspaceOpened() }`. The view reads `OpenWorkStore`, `PreferencesStore` for `@login`, and `@Environment(\.openSettings)`. Row labels include title, kind, `repo#number`, author and an absolute date; pull requests get a “PR” marker. No per-item restore and no hidden-items sheet. It does not post notifications and does not touch `TriageStore`.

#### 14. `Sources/DispatchApp/Views/DetailPaneView.swift` (Modify)

* **Type / Scope**: Detail inspector.
* **Proposed Changes**: Add an Open Work branch that reads `openWorkStore.selectedItem` when GitHub is active and accepts `OpenWorkItem`. Use `store.githubService` for `fetchIssueDetails`; render a detail 401/403 inline without changing the list. Replace Archive/Trash with “Open on GitHub” and “Hide from Open Work”. Call `OpenWorkDispatcher.makePayload` + `performDispatch`; on a detail fetch failure show an alert whose actions call `makeTitleOnlyPayload` or cancel. Leave the old GitHub `TriageKind` branches in place until item 20.

#### 15. `Sources/DispatchApp/Views/SidebarView.swift` (Modify)

* **Type / Scope**: Navigation.
* **Proposed Changes**: Remove the GitHub filter section, `filterColor` and `filterCount`. Apply the sidebar rule: “N open items” only after a successful load with at least one visible item; otherwise “—”. Keep the Gmail unread badge. Remove the bottom “Live” indicator and the `TriageStore.isLoading` read; keep the settings gear. Inject `OpenWorkStore` through the environment.

#### 16. `Sources/DispatchApp/Views/TriageStreamView.swift` (Modify)

* **Type / Scope**: Gmail stream.
* **Proposed Changes**: Leave the GitHub branches in place for Slice 4; they are unreachable for the Gmail workspace. Make the empty state Gmail-specific. Item 20 removes the dead branches with the `TriageKind` cases and the `reviewBadge`/`ciBadge` helpers. Do not delete the cases early.

#### 17. `README.md` (Modify)

* **Type / Scope**: Product documentation.
* **Proposed Changes**: Replace the GitHub notifications/backfill description with Open Work: involvement scope (authored, assigned, mentioned, commented), the exclusion of subscription-only and review-requested items, 15-minute refresh after first open, no unread state, no repository configuration, the 400-item cap, the last-run summary, the key-rename limitation, the shortcut legend, and the classic versus fine-grained token behavior. Remove or rewrite the notification references at the existing GitHub sections.

### Slice 5: Remove the old GitHub paths

PreferencesStore removes the UserDefaults PAT after Settings and Onboarding have switched to `isGitHubConfigured` in Slice 3. TriageStore and TriageKind are cleaned after every view has stopped using the old GitHub cases.

#### 18. `Sources/DispatchApp/State/PreferencesStore.swift` (Modify)

* **Type / Scope**: Preferences.
* **Proposed Changes**: Remove `trackedRepositories`, `trackedOwners`, their keys and initializers, `normalizedTrackedRepositories`, `normalizedTrackedOwners`, `githubPAT`, and the `dispatchGitHubBackfillRequested` notification name. After removing those call sites, delete `GitHubService.normalizeRepositories` and `normalizeOwners`. Keep `githubUsername` and the in-memory `isGitHubConfigured` added in Slice 3. Do not own the PAT migration; `DispatchApp` owns it.

#### 19. `Sources/DispatchApp/State/TriageStore.swift` (Modify)

* **Type / Scope**: Gmail state store.
* **Proposed Changes**: Remove `gitHubItems`, `GitHubFilter`, `gitHubFilter`, `filteredGitHubItems`, `setGitHubBackfill`, `mergedGitHubItems`, `dismissLocally`, `dismissBackfillItemLocally`, `dismissedGitHubKeys` and `dismissedGitHubIssueIDs`. Keep `activeWorkspace`, `githubService` and `TriageSource.gitHub`. `activeItems` returns an empty `.gitHub` fallback; `setItems(_:for: .gitHub)` is a no-op; `unreadCount(for: .gitHub)` returns 0; `selectedItem` is Gmail-only. Remove `isLoading`. Make `archive`, `trash` and `mutateItem` Gmail-only, then remove `GitHubService.dismissNotification` and `unsubscribeNotification`. Use the Slice 3 `SnapshotData.init(from:)` and `load(from:)`; remove both `loadSnapshot` assignments to `gitHubItems` and `dismissedGitHubKeys`. Save `gitHubItems: []` and `dismissedGitHubKeys: nil`. On a Gmail decode failure, rename the file to `snapshot.corrupt-<ISO8601>.json`, log once, start with empty Gmail state, and allow the next save. The PAT and hidden-key migration is not here; `DispatchApp.init` owns it.

#### 20. `Sources/DispatchApp/Models/TriageItem.swift` and the remaining dead view branches (Modify)

* **Type / Scope**: Shared model cleanup and dead-code removal.
* **Proposed Changes**: Remove the `.gitHubIssue`, `.gitHubPullRequest` and `.gitHubNotification` cases from `TriageKind`; delete `ReviewStatus` and `CheckSuiteStatus` outright; delete the `isBackfillDerived` and `canonicalKey` properties. Remove the now-dead GitHub branches in `TriageStreamView` (`streamTitle`, `snippetText`, `badgesView`, `reviewBadge`, `ciBadge`) and `DetailPaneView` (`detailContent(for:)` `.gitHub` arm, `gitHubDetailView`, `statusPills`, `loadGitHubDetails`, `dispatchToAgent`) in the same edit so the switches stay exhaustive. Keep `TriageSource`, `TriageItem`, `GitHubIssueDetail`, `GitHubComment`, `TerminalApp`, `AgentCLI` and the dispatch payload. Old GitHub items are ignored by the tolerant snapshot read.

#### 21. `Tests/DispatchAppTests/TriageStoreTests.swift` (Modify)

* **Type / Scope**: Gmail, snapshot and migration tests.
* **Proposed Changes**: Remove the GitHub filter, backfill, merge, notification and `gitHubItems` tests. Make `makeTestItem` `.email`-only. Keep Gmail action and unread tests. Add raw JSON fixtures for: an old snapshot containing `gitHubItems` and `dismissedGitHubKeys` (Gmail items survive), a corrupt snapshot (renamed and not overwritten), a missing snapshot (still saves), and the explicit `.gitHub` switch fallbacks. Migration assertions live in `OpenWorkMigrationTests` (item 22).

#### 22. `Tests/DispatchAppTests/OpenWorkMigrationTests.swift` (Create)

* **Type / Scope**: Migration tests.
* **Proposed Changes**: Test `LegacyStateMigrator` directly with an injected `UserDefaults` suite, a `KeychainStoring` fake, and raw JSON snapshots. Cover: a valid PAT is copied to the Keychain, verified and deleted from defaults; a failed write keeps the defaults value for manual recovery and returns `isConfigured == false` with `needsReconnect == true` (no two-source provider); hidden keys union into an existing new set; prefixes are stripped longest-first; `gh:thread:` keys are dropped; a second run is idempotent.

### Verification Plan

* **Compilation/Build**: `swift build` and `swift build --build-tests` after each slice; `swift build -c release` before handoff.
* **Unit Tests**: `swift test --no-parallel`, matching CI. Do not use `--filter OpenWork` as the slice gate.
* **Static Analysis & Linting**: No linter is configured. Use a clean build directory and fail if `swift build --build-tests 2>&1 | grep -q "warning:"` returns true.
* **Coverage Matrix**:

| Invariant | Test |
| --- | --- |
| A successful refresh updates the summary, complete or truncated | `OpenWorkStoreTests` |
| A truncated refresh does not prune hidden keys | `OpenWorkStoreTests` |
| A failed refresh never changes items or the summary | `OpenWorkStoreTests` |
| Hiding is idempotent and survives a fresh store | `OpenWorkStoreTests` |
| Hide → refresh → undo still restores the item | `OpenWorkStoreTests` |
| A first launch fetches only after `noteWorkspaceOpened()` | `OpenWorkStoreTests` |
| A failed attempt is throttled to 15 minutes | `OpenWorkStoreTests` |
| A second refresh awaits the in-flight task | `OpenWorkStoreTests` |
| `clear()` keeps hides, cancels the task and discards a stale result | `OpenWorkStoreTests` |
| Duplicate pages do not set `truncated` | `OpenWorkFetchTests` |
| Exactly 400 matches are complete | `OpenWorkFetchTests` |
| A page-two 404 throws `notFound` | `OpenWorkFetchTests` |
| `total_count` maps to `matchedCount` | `OpenWorkFetchTests` |
| Nil author/URL mapping follows the rules | `OpenWorkFetchTests` |
| One refresh per due interval, first fetch on first open | `OpenWorkStoreTests` |
| An old snapshot loads without losing Gmail items | `TriageStoreTests` |
| Old hidden keys seed the new set before store init | `OpenWorkMigrationTests` |
| The PAT is copied, verified and deleted from defaults | `OpenWorkMigrationTests` |
| A failed Keychain write returns `isConfigured == false` and `needsReconnect` | `OpenWorkMigrationTests` |
| A corrupt snapshot is quarantined and not overwritten | `TriageStoreTests` |
| `unreadCount(for: .gitHub)` returns 0 | `TriageStoreTests` |
| Header/empty-state predicates render the expected copy | `OpenWorkViewStateTests` |
| 401, 403, transport, notFound, decoding and server choose different actions | `OpenWorkViewStateTests` |

* **Integration**: Run the app against a real account as a manual observation, not a requirement. Verify one search request populates the list; a 403 test fixture keeps rows and shows the matching action; closing an issue upstream removes it on the next success; hide plus relaunch keeps it hidden; offline launch shows the last-run summary and the error, not “All Caught Up”.
* **Rollback Check**: Load a snapshot written by the current release in the new build and confirm Gmail items survive. Then run the current release against a snapshot written by the new build and confirm it still opens and authentication works from the Keychain. GitHub hide history is not restored in the old build by design.
