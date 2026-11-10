# GitHub Open Work Import

* **Author:** Dispatch maintainer
* **Status:** Draft
* **Date:** 2026-11-09

--------------------------------------------------------------------------------

## Overview

Dispatch's GitHub workspace currently combines two feeds: a live search for open issues assigned to the authenticated user, polled every 45 seconds, and a backfill that imports open issues and pull requests involving the user, refreshed every 15 minutes and merged into the same list. This design replaces both with one **Open Work** view backed by a single involvement query, held in memory and refreshed every 15 minutes while the app runs.

The change removes the merge engine, the assigned-issue poller, the GitHub smart filters, the two dismissal stores, and the free-text owner and repository fields. Imported work gets its own selection, counts, and status. It is never counted as unread. A refresh replaces the list only after a complete run; a failed run keeps the previous list and marks it stale. The view states its scope in one sentence and shows what happened on the last attempt.

## The Problem

The current GitHub side cannot answer three basic questions: did the import run, what did it bring in, and why is this item here.

**The UI reports success no matter what happened.** Each per-repository or per-owner fetch is wrapped in `try?` and returns an empty array on failure (`GitHubService.swift:255-279`). The coordinator catches every remaining error and does nothing (`SyncCoordinator.swift:161-164`). A missing token, a 403, a repository the token cannot read, and a genuinely empty result all render the same. `isLoading` is never set true (`TriageStore.swift:77`), so the sidebar shows a green "Live" dot even when sync has been failing for hours. "Backfill Now" posts a notification that only the main window's scene listens for (`SettingsView.swift:189-194`, `DispatchApp.swift:25-37`); with the main window closed it does nothing, and a second click during a run also returns silently (`SyncCoordinator.swift:149`).

**A partial result replaces the whole set.** The visible list is rebuilt from exactly what the last fetch returned (`TriageStore.swift:216-224`). One failed source therefore deletes that source's rows. Because dismissals are pruned by intersecting with the same result (`TriageStore.swift:219`), a failed source also loses the record of what the user dismissed, so those items return on the next successful run. Two different dismissal stores exist, keyed differently, and neither applies to the other (`TriageStore.swift:91-97`, `163-172`).

**Caps are silent.** The default is three pages per source, or 300 items (`GitHubService.swift:236`). The store truncates to 500 by array position (`TriageStore.swift:64-70`, `198-202`), and GitHub caps search at 1,000. The payload's `total_count` is decoded and discarded (`GitHubService.swift:432-434`). A user cannot distinguish a complete list from a truncated one.

**The UI treats a backlog as an inbox.** Imported items arrive read (`GitHubService.swift:524`), so the GitHub unread badge can show zero while hundreds of rows exist (`TriageStore.swift:176-183`). The empty state says "All Caught Up" whether the fetch returned nothing or failed (`TriageStreamView.swift:41-58`). The smart filters cannot match imported pull requests because review and CI status are hardcoded (`GitHubService.swift:499-506`). Archive and Trash only hide an imported item locally (`TriageStore.swift:356-360`, `415-419`), but the detail pane labels them as notification actions (`DetailPaneView.swift:245-260`), and there is no undo or list of hidden items.

**The live feed duplicates the import and fights it.** The live feed is `is:issue is:open assignee:@me` (`GitHubService.swift:115`), a subset of an involvement query. It creates items as unread (`GitHubService.swift:195`), re-emits them every 45 seconds, and preserves local read state only for imported items (`TriageStore.swift:262-265`). Pressing `u` on an assigned issue is reverted within one poll, and that item is counted in the badge.

**Scope is configured by guesswork.** Settings accepts free-text owner and repository lists and runs them as a union (`GitHubService.swift:250-288`). Malformed lines are silently dropped while remaining on screen (`GitHubService.swift:292-332`). The copy says the repository list narrows the import, but filling both lists imports everything the owners own (`SettingsView.swift:184`). Adding your own account as an owner imports every open issue across all your repositories, including other people's work, and then truncates at 500.

The published application is ad-hoc signed and not notarized, and its Google refresh token is stored but never used. Those are separate release and authentication defects. They are not solved here, but they make the same screens untrustworthy, so this design must not add another silent failure on top of them.

## Goals

1. Replace the merged GitHub list with one **Open Work** view that shows every open issue and pull request involving the authenticated user within the token's access: authored, assigned, mentioned, commented on, or subscribed.
2. Use one involvement query with no owner or repository configuration. Remove the free-text fields.
3. Refresh every 15 minutes while the app runs and when the view opens. Replace the visible set only after a complete run.
4. On failure, keep the previous set, leave the last-success time unchanged, and show the error. Never delete rows because a fetch failed.
5. Show in the view header: running state, last success, matched count, shown count, and a truncation notice when the API cap is reached.
6. Group items by repository, keep the selected item across refreshes, and drop closed and merged items on the next successful refresh.
7. Never count an imported item as unread. The GitHub sidebar row shows a neutral count of visible open items, not an unread badge.
8. Provide two row actions: "Open on GitHub" and "Hide from Open Work". Hiding is local, undoable, and its keys persist across relaunch. `u` and `#` do nothing in this view.
9. Remove the live assigned-issue feed, its ETag polling, `GitHubFilter`, the sidebar filter section, `mergedGitHubItems`, `isBackfillDerived`, and both existing dismissal stores.
10. Keep the cost bounded: one page request for a user with 89 matching items, at most four requests per refresh, and no per-repository fan-out.

Success means a user can open the GitHub workspace and tell within one screen whether the import ran, when it last succeeded, how many items it found, and why an item is missing or stale. It also means a failed refresh cannot make work disappear or resurrect work the user hid.

## Non-Goals

* Changing GitHub state. Dispatch will not close issues, merge pull requests, mark notifications read, or unsubscribe from anything from Open Work.
* Review-requested pull requests that involve the user in no other way. They are excluded in this version, and the view copy must say so.
* Importing every open item in every repository the token can read, including other people's backlog.
* Fetching CI or review metadata for imported pull requests. Unknown values remain unknown.
* Persisting imported items across relaunch in this version. Only hidden-item keys persist.
* Gmail behavior, a general notification feed, multi-account support, and macOS signing or notarization.
* Guaranteed completeness above the GitHub search limit. The view discloses truncation instead.

## Open Questions

* **Question 1**: Do fine-grained personal access tokens and SSO-protected organizations need explicit support in this version, or is a documented limitation acceptable?
* **Question 2**: Above 400 matching items, should the view apply a hard cap with a banner, or narrow the default scope?

--------------------------------------------------------------------------------

## Critical User Journeys (CUJs)

### CUJ 1: First open after a token is saved

* **Given**: A valid PAT is stored and no Open Work data has been loaded in this launch.
* **When**: The user selects the GitHub workspace.
* **Then**: The view shows a loading state, runs one involvement search, and renders the results grouped by repository. The header reads "89 open · just now". The GitHub sidebar count shows 89, not an unread count. No item carries an unread dot.

### CUJ 2: A refresh fails

* **Given**: 89 items are visible from an earlier successful run.
* **When**: The 15-minute refresh receives HTTP 403, 401, or a network error.
* **Then**: The 89 rows remain. The header marks the data stale, keeps the previous last-success time, and shows the reason plus a Retry button. Hidden items stay hidden. No dismissal record is pruned.

### CUJ 3: Work closes upstream

* **Given**: Item `owner/repo#42` is visible and selected.
* **When**: A complete refresh no longer returns it because the issue was closed or the pull request merged.
* **Then**: The row disappears, selection moves to the nearest remaining item, and a transient notice reports how many items left the list.

### CUJ 4: Hiding an item

* **Given**: An item is visible in Open Work.
* **When**: The user presses `e` or chooses "Hide from Open Work".
* **Then**: The row disappears and a toast offers Undo. The key is written to UserDefaults. After relaunch, the item remains hidden until the user restores hidden items from the header menu.

### CUJ 5: Offline launch

* **Given**: The app has no network and no Open Work data in memory.
* **When**: The user opens the GitHub workspace.
* **Then**: The view says the import has not run, names the network failure, and offers Retry. It does not say "All Caught Up".

## Technical Plan (Architecture)

### Component map

```text
GitHubService.fetchOpenWork()          one involvement search, 100 per page, ≤4 pages
        │
        │  OpenWorkFetchResult(items, matchedCount, truncated, requestCount)
        ▼
SyncCoordinator                        owns the 15-minute timer, sleep/wake and network gate
        │
        │  onOpenWorkUpdated(OpenWorkUpdate)
        ▼
OpenWorkStore (@MainActor, @Observable)
        │  items, status, hiddenKeys, selection, groupedItems
        ├── SidebarView                 neutral open-item count
        ├── OpenWorkView                grouped list, status header, banners
        └── DetailPaneView              Open on GitHub, Hide, Dispatch to agent
```

Four components change role:

* `GitHubService` gains one method and loses the per-repository and per-owner fan-out.
* `SyncCoordinator` stops merging and stops tracking backfill timestamps; it schedules one Open Work refresh and publishes one result object.
* `OpenWorkStore` is new. It owns the visible list, status, hidden keys and selection. It does not persist items.
* `TriageStore` becomes Gmail-only. Its GitHub arrays, filters and merge helpers are removed.

### Data model

**`OpenWorkItem`** is a separate value type, not a `TriageItem`. Imported work is not triage mail, and keeping it out of `TriageItem` avoids changing a type that is persisted in the Gmail snapshot.

* `key: String` — `owner/repo#number`, lowercased, stable across refreshes.
* `repository: String` — `owner/repo`, preserving display case.
* `number: Int`
* `kind: .issue(state: String) | .pullRequest(isDraft: Bool)`
* `title: String`
* `authorLogin: String`
* `authorAvatarURL: URL?`
* `updatedAt: Date`
* `labels: [String]`
* `webURL: URL`

No relationship field in this version. The query does not return why an item matched, and inventing a reason from labels would repeat the current `tags` mistake (`TriageStore.swift:114-125`).

**`OpenWorkStatus`** is the only thing the UI needs to explain freshness:

* `phase: .idle | .running | .ready | .stale`
* `lastAttempt: Date?`
* `lastSuccess: Date?`
* `matchedCount: Int`
* `shownCount: Int`
* `hiddenCount: Int`
* `truncated: Bool`
* `errorText: String?`
* `requestCount: Int`

`lastSuccess` is in memory only. After relaunch it is nil and the header says "not imported yet" until the first success.

**`OpenWorkUpdate`** is the payload from the coordinator:

* `result: .success([OpenWorkItem]) | .failure(OpenWorkFailure)`
* `status: OpenWorkStatus`

A failure carries no item array. The store keeps what it already has.

### Fetch

`GitHubService.fetchOpenWork()` performs one search:

```text
GET /search/issues
  q = is:open involves:@me
  sort = updated
  order = desc
  per_page = 100
```

`involves:@me` covers authored, assigned, mentioned, commented on, and subscribed items, and returns pull requests as well as issues. This matches the goals; review-requested pull requests are the known gap.

Rules:

* Request up to 4 pages (400 items), or stop earlier when a page returns fewer than 100 items.
* Read `total_count` from the first page and keep it as `matchedCount`.
* Deduplicate by `key` across pages. Search pagination can shift while the user works, so a duplicate is expected.
* Set `truncated` when `matchedCount > items.count`.
* Do not fan out per repository or per owner. One query, bounded pages.
* Treat HTTP 401, 403, 5xx, decoding failure and transport failure as a failed attempt with a specific message. A 403 includes the rate-limit reset time when the header is present.
* No retry inside the fetch. One attempt per refresh; the Retry button and the next 15-minute tick are the recovery path.

### Refresh and failure

`SyncCoordinator` owns scheduling so the existing sleep, wake and network handling stays in one place.

* Refresh on the first transition to the GitHub workspace, then every 15 minutes while the app is running.
* A dedicated 15-minute task, not `pollCycleCount % 20`. Sleep cancels it; wake restarts it and triggers one refresh. Manual refresh does not change the next scheduled time.
* Only one refresh may run at a time. A manual request during a run returns the current status instead of starting a second request.
* On success, publish the full item array and a `.ready` status.
* On failure, publish no items and a `.stale` status that keeps the previous `lastSuccess` and carries `errorText`.
* Closed and merged items leave only on a successful refresh, because only a successful refresh is known to be complete.

### Store behavior

`OpenWorkStore` applies updates atomically on the main actor.

* On success: replace items, recompute groups, keep `selectedKey` if it still exists, otherwise select the item nearest the old position. Report the number removed.
* On failure: keep items and selection unchanged; update status only.
* Hidden keys are stored in UserDefaults under `dispatch.openWorkHiddenKeys`, lowercased and capped at 1,000. Applying an update filters hidden items out of the visible list and increments `hiddenCount`.
* Hiding and unhiding update the set immediately, persist it, and show an undo toast.
* `groupedItems` groups by repository and sorts groups by repository name, and items inside a group by `updatedAt` descending.
* The store exposes `refresh()` as an injected closure wired to `SyncCoordinator` in the composition root, so the view does not post notifications.

### Views

* `MainSplitView` chooses `TriageStreamView` for Gmail and `OpenWorkView` for GitHub. It no longer passes GitHub items through `TriageStore.activeItems`.
* `SidebarView` keeps Gmail unread counts. The GitHub row shows `openWorkStore.visibleCount` in a neutral capsule. The GitHub filter section is removed.
* `OpenWorkView` replaces the GitHub list:
  * Header: `89 open · updated 2m ago` with a Refresh button.
  * Stale banner: reason, last success, Retry.
  * Truncation banner: "Showing 400 of 1,284".
  * Empty states: never imported, imported but empty, failed with no data.
  * Repository sections with a count per section.
  * Row: title, repository `#number`, author, relative update time, issue state or draft marker.
* `DetailPaneView` gets an Open Work branch: "Open on GitHub" and "Hide from Open Work" replace Archive and Trash. The existing issue detail fetch and the `⌘⇧A` agent dispatch remain.
* Keyboard routing follows `activeWorkspace`: `j`/`k` navigate the active store, `e` hides in Open Work, `u`, `s` and `#` do nothing in Open Work. Gmail shortcuts are unchanged.
* Settings loses the Open Work scope fields and the Backfill Now button. A read-only line states the scope and the last result.

### Removals and compatibility

* Remove `TriageStore.gitHubItems`, `gitHubFilter`, `filteredGitHubItems`, `setGitHubBackfill`, `mergedGitHubItems`, `dismissBackfillItemLocally`, `dismissLocally`, `dismissedGitHubKeys`, `dismissedGitHubIssueIDs`, and `unreadCount(for: .gitHub)`.
* Remove `TriageItem.isBackfillDerived` and the GitHub cases from `TriageKind`. Only Gmail uses `TriageItem` afterwards.
* Remove `GitHubService.fetchAssignedIssues`, `fetchOpenIssuesAndPullRequests`, `normalizeRepositories`, `normalizeOwners`, and the per-source helpers.
* Remove `GitHubFilter`, the sidebar filter section, and the filter counts.
* Remove `PreferencesStore.trackedRepositories`, `trackedOwners`, and both normalizers, plus the `dispatchGitHubBackfillRequested` notification.
* Keep `SnapshotData.gitHubItems` in the file format but stop writing new values. Give `SnapshotData` a custom decoder that treats `gitHubItems` and `dismissedGitHubKeys` as optional and ignores a decode failure in those fields, so an old snapshot cannot wipe the Gmail cache.
* Keep `TriageSource.gitHub` for workspace selection only.

### Rate limits and bounds

* Worst case is 4 requests per refresh at 15-minute intervals: 16 requests per hour against the 30-per-minute search limit and far below the 5,000-per-hour core limit.
* A typical user with fewer than 100 matches costs one request per refresh.
* There is no per-repository fan-out, so request count does not grow with repository count.
* The 400-item cap is disclosed, not hidden.

### Concurrency

* `GitHubService` is a stateless `Sendable` class, unchanged.
* `SyncCoordinator` remains an actor and serializes refreshes; `onOpenWorkUpdated` is a `@Sendable` callback.
* `OpenWorkStore` is `@MainActor @Observable`, like `TriageStore`.
* The result crosses from the coordinator to the store as one immutable value; the store never reads coordinator state.

--------------------------------------------------------------------------------

## Alternatives Considered

### Alternative A: Keep the merged feed and add a status row

* **Pros**: Smallest code change. One list, one selection model, and the existing tests keep working.
* **Cons**: The live assigned feed re-marks items unread every 45 seconds (`GitHubService.swift:195`, `SyncCoordinator.swift:281-291`), so imported work cannot stay out of the unread count while both feeds share `gitHubItems`. The 500-item cap and dismissal pruning still apply to the merged array.
* **Reason for Rejection**: It cannot satisfy the core invariant that imported work is never unread, and it leaves the partial-failure data loss intact.

### Alternative B: Add an Open Work filter or tab to the existing list

* **Pros**: No new store or selection model. Users keep one screen.
* **Cons**: The underlying array is still ordered by merge position, not by repository or update time. The 500-item cap still truncates by position, provenance still depends on an ID prefix, and both dismissal stores remain.
* **Reason for Rejection**: It changes what is visible without changing the state model that produces the bugs. Repository grouping and correct counts would still be computed over a list that mixes notifications and backlog.

### Alternative C: Persist imported items in the existing snapshot

* **Pros**: Instant display on cold start, and hiding plus last-success status survive relaunch.
* **Cons**: `SnapshotData` has no schema version and its decoder clears the cache on a model mismatch (`TriageStore.swift:309-327`). Adding item persistence requires a versioned format, a migration path, and a strategy for stale data at launch. It also stores a second copy of data that GitHub already owns.
* **Reason for Rejection**: Deferred, not dismissed. The first version is in memory, which removes the migration risk. Persistence can be added behind a schema version once cold-start demand is demonstrated.

### Alternative D: One-time import with a manual refresh

* **Pros**: Minimal network use and the simplest possible scheduling. No periodic housekeeping.
* **Cons**: Closed and merged items linger forever unless the user remembers to refresh. The view cannot honestly claim the list is current. A one-time import also makes "Backfill Now" mean "replace my snapshot", which needs different copy and a confirmation.
* **Reason for Rejection**: A full refresh costs one request for a typical user and at most ten, so the 15-minute cadence is cheap. The user also chose periodic refresh over a one-time import.

### Alternative E: Enumerate every repository the token can read

* **Pros**: Truly every open issue and pull request in the accessible set, independent of GitHub's involvement semantics.
* **Cons**: It imports other people's backlog. Request count scales with repository count rather than with the user's work: 52 repositories today, potentially hundreds in an organization. It also multiplies the ways a partial fetch can fail.
* **Reason for Rejection**: The goal is the user's work, not every repository's open issues. The involvement query matches the intent and keeps the request count bounded.

### Alternative F: Use the GitHub notifications endpoint as the source

* **Pros**: GitHub supplies the reason for each notification (`mention`, `review_requested`, `ci_activity`), and read state already exists server-side.
* **Cons**: `/notifications` returns unread threads, not all open work. It requires a classic token with the notifications scope, which conflicts with the fine-grained token path. It also reintroduces the merge between notifications and open work that this design removes.
* **Reason for Rejection**: It answers "what changed" rather than "what is open". The two questions need different sources and different views.

### Alternative G: GraphQL search instead of REST

* **Pros**: One query can return `totalCount`, page info and only the needed fields. It avoids over-fetching.
* **Cons**: Fine-grained token support and SSO authorization must be verified before relying on it. It adds a second protocol, a second error surface, and a second authentication path to a small application. The REST search endpoint already returns `total_count` and works with the classic token the product documents.
* **Reason for Rejection**: REST covers the requirements for this version. Revisit GraphQL only if pagination or the 1,000-result ceiling becomes a demonstrated limit.

### Alternative H: Remove the feature and rely on GitHub saved views

* **Pros**: No code, no polling, no new state. GitHub already filters open work by involvement, assignment and review request.
* **Cons**: It gives up the local detail view, the `⌘⇧A` agent dispatch path, and the single-window Gmail plus GitHub workflow. It also contradicts the stated goal of keeping existing work inside Dispatch.
* **Reason for Rejection**: The user explicitly wants existing open work in the application. This alternative remains the fallback if Open Work cannot name a task it does better than `github.com/issues`.

--------------------------------------------------------------------------------

## Non-Functional Requirements

**Security and privacy.** The PAT remains in the macOS Keychain. The only new network call is the GitHub search endpoint, already reached through `GitHubService`; no token is written to logs or UserDefaults. Hidden-item keys are repository names and numbers, not message content. The tolerant snapshot decoder must not log snapshot contents.

**Performance and cost.** A refresh costs one request for a user below 100 matches and at most four requests at the 400-item cap. At a 15-minute interval that is 16 requests per hour against a 30-per-minute search limit. The store holds at most 400 value types in memory. Grouping is recomputed on each update, not per row render. No new background CPU runs while the app sleeps.

**Rollout and rollback.** There is no server change and no data migration. The old snapshot stays readable because `gitHubItems` and the dismissal key are decoded as optional and then ignored. Reverting the release leaves the old snapshot fields unused; hidden-item keys live under a new UserDefaults key and are harmless if left behind. The feature can ship behind no flag because it replaces a path that is already failing visibly; if rollback is needed, reverting the release restores the old merge path and the old snapshot still loads.

**Compatibility.** macOS 14 and later. Classic PATs work. Fine-grained PATs and SSO organizations may return a smaller set, and the view copy states that the scope is what the token can read.

**Accessibility.** The status header, stale banner, and truncation banner are text, not color alone. Repository sections carry headings. Keyboard navigation keeps `j`/`k`, and hiding announces through the existing toast. The refresh control has a label and reports its running state.

--------------------------------------------------------------------------------

### Additional Resources

* `concepts_brief_backfill.md` — brainstorm brief, Goldfish findings and the alternatives weighed before drafting.
* `design_draft.md` — original application design. This document replaces its GitHub backfill section; the Gmail and agent-dispatch sections remain in force.

### Future Improvements

* **Relationship data:** Add Assigned, Authored and Mentioned grouping once evidence shows users need to know why each item matched. It requires extra involvement queries per relationship and a merge by item key.
* **Persistence:** Add a versioned Open Work snapshot and a migration path if cold-start demand is proven. The current version deliberately holds items in memory.
* **CI status and merge:** A separate follow-up design. List-wide CI requires per-pull-request detail and check-run requests, or a GraphQL query, and merge requires write permission, a confirmation flow, and branch-protection error handling. Neither is part of this read-only version.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Target Files to Create/Modify

#### 1. `Sources/DispatchApp/Models/OpenWorkItem.swift` (Create)

* **Type / Scope**: Model type.
* **Proposed Changes**: Add `OpenWorkItem`, `OpenWorkItemKind` (`.issue(state:)`, `.pullRequest(isDraft:)`), `OpenWorkStatus`, `OpenWorkUpdate`, and `OpenWorkFailure`. `OpenWorkItem.key` is `owner/repo#number` lowercased; `repository` preserves display case. `OpenWorkStatus` carries the phase, timestamps, matched/shown/hidden counts, truncation, error text, and request count. This file is the only new model surface and exists so imported work never enters `TriageItem` or the Gmail snapshot.

#### 2. `Sources/DispatchApp/Services/GitHubService.swift` (Modify)

* **Type / Scope**: Network service.
* **Proposed Changes**: Add `fetchOpenWork() async throws -> OpenWorkFetchResult`, where the result contains items, `matchedCount`, `truncated`, and `requestCount`. The fetch calls `search/issues?q=is:open+involves:@me&sort=updated&order=desc&per_page=100`, reads `total_count`, pages up to four times or until a short page, deduplicates by `key`, and maps JSON to `OpenWorkItem`. Remove `fetchAssignedIssues`, `fetchOpenIssuesAndPullRequests`, `requestAllPages`, `normalizeRepositories`, `normalizeOwners`, and the per-repo/per-owner decode helpers. Remove the now-unreachable `dismissNotification`, `unsubscribeNotification`, and `fetchCheckRuns`. Keep `fetchIssueDetails` and `makeRequest` unchanged.

#### 3. `Sources/DispatchApp/Services/SyncCoordinator.swift` (Modify)

* **Type / Scope**: Actor and scheduler.
* **Proposed Changes**: Remove all backfill properties, `setBackfillConfiguration`, `performGitHubBackfill`, `backfillGitHubIfNeeded`, `refreshBackfillIfDue`, `pollCycleCount`, `lastGitHubETag`, and `syncGitHub`. Add `onOpenWorkUpdated: (@Sendable (OpenWorkUpdate) -> Void)?`, an `openWorkTask`, and `refreshOpenWork()`. The scheduler starts on `start()`, triggers once when the GitHub workspace is first opened (through a store call), and repeats on an injected 15-minute interval. Sleep cancels the task; wake restarts it and triggers one refresh. The actor keeps `isRefreshingOpenWork`, the last attempt, last success, and the last error. On success it publishes items and a `.ready` status; on failure it publishes no items and a `.stale` status. `performSyncCycle` becomes Gmail-only. Inject the interval and sleeper so tests do not wait 15 minutes.

#### 4. `Sources/DispatchApp/State/OpenWorkStore.swift` (Create)

* **Type / Scope**: Main-actor observable store.
* **Proposed Changes**: Hold `items`, `status`, `hiddenKeys`, `selectedKey`, and computed `groupedItems` and `visibleCount`. Apply `OpenWorkUpdate` atomically: success replaces items, preserves selection by key or the nearest index, and reports removals; failure changes status only. Read and write hidden keys under `dispatch.openWorkHiddenKeys`, capped at 1,000, lowercased. Expose `hide(key:)`, `unhide(key:)`, `undoHide()`, `refresh()`, `selectNext()`, `selectPrevious()`, and `restoreAllHidden()`. `refresh()` calls an injected async closure wired to the coordinator, so no `NotificationCenter` is involved.

#### 5. `Sources/DispatchApp/State/TriageStore.swift` (Modify)

* **Type / Scope**: Gmail state store.
* **Proposed Changes**: Remove `gitHubItems`, `GitHubFilter`, `gitHubFilter`, `filteredGitHubItems`, `setItems(_:for: .gitHub)`, `setGitHubBackfill`, `mergedGitHubItems`, `dismissLocally`, `dismissBackfillItemLocally`, `dismissedGitHubKeys`, `dismissedGitHubIssueIDs`, and the GitHub branch of `unreadCount(for:)`. `activeItems` and `selectedItem` become Gmail-only. Give `SnapshotData` a custom `init(from:)` that decodes `gmailItems` strictly and `gitHubItems` plus `dismissedGitHubKeys` as optional, ignoring their decode failure. Save `gitHubItems: []` from now on. Keep the existing Gmail actions unchanged.

#### 6. `Sources/DispatchApp/State/PreferencesStore.swift` (Modify)

* **Type / Scope**: Preferences.
* **Proposed Changes**: Remove the `trackedRepositories` and `trackedOwners` keys, properties, initializers and normalizers. Keep `githubUsername`, which the scope sentence needs. Remove the `dispatchGitHubBackfillRequested` notification name. No new preference is introduced; hidden keys belong to `OpenWorkStore`.

#### 7. `Sources/DispatchApp/App/DispatchApp.swift` (Modify)

* **Type / Scope**: Composition root.
* **Proposed Changes**: Add `@State private var openWorkStore = OpenWorkStore()`. Inject it into the window and Settings. Wire `openWorkStore.refreshAction` to `coordinator.refreshOpenWork()`, and `coordinator.setOnOpenWorkUpdated` to `openWorkStore.apply(_:)`. Remove the `dispatchGitHubBackfillRequested` listener and the `setBackfillConfiguration` call. Keep Gmail service creation, snapshot loading and the terminate-save hook.

#### 8. `Sources/DispatchApp/Views/MainSplitView.swift` (Modify)

* **Type / Scope**: Layout and keyboard routing.
* **Proposed Changes**: Choose `TriageStreamView` for Gmail and `OpenWorkView` for GitHub instead of routing both through `store.activeItems`. Send `j`/`k` to the active store, `e` to `openWorkStore.hide` on GitHub, and leave `u`, `s` and `#` as Gmail-only actions. Update `dispatchCurrentItem()` to take an `OpenWorkItem` for GitHub and keep the existing `GitHubIssueDetail` and agent dispatch path. Remove the `.gitHubIssue`, `.gitHubPullRequest` and `.gitHubNotification` switch cases.

#### 9. `Sources/DispatchApp/Views/SidebarView.swift` (Modify)

* **Type / Scope**: Navigation.
* **Proposed Changes**: Remove the GitHub filter section, `filterColor` and `filterCount`. The GitHub workspace row shows `openWorkStore.visibleCount` in a neutral capsule rather than `unreadCount`. Keep the Gmail unread badge. Inject `OpenWorkStore` through the environment.

#### 10. `Sources/DispatchApp/Views/OpenWorkView.swift` (Create)

* **Type / Scope**: New primary view.
* **Proposed Changes**: Build the list described in the Technical Plan: header with count, last success and Refresh; stale and truncation banners; three empty states; repository sections; rows with title, `repo#number`, author, relative time and state or draft marker; hidden-items menu with restore. The view reads only `OpenWorkStore`. It does not post notifications and does not touch `TriageStore`.

#### 11. `Sources/DispatchApp/Views/TriageStreamView.swift` (Modify)

* **Type / Scope**: Gmail stream.
* **Proposed Changes**: Remove the GitHub title branch and the GitHub row snippets, badges and filter references. The view becomes Gmail-only, with a Gmail-specific empty state. Keep the existing row layout for email metadata.

#### 12. `Sources/DispatchApp/Views/DetailPaneView.swift` (Modify)

* **Type / Scope**: Detail inspector.
* **Proposed Changes**: Split the GitHub branch into an Open Work branch that accepts `OpenWorkItem`. Keep `fetchIssueDetails` for the body and comments. Replace Archive/Trash with "Open on GitHub" and "Hide from Open Work". Keep `⌘⇧A` dispatch. Remove the notification labels and the `.gitHubNotification` handling.

#### 13. `Sources/DispatchApp/Views/SettingsView.swift` (Modify)

* **Type / Scope**: Preferences UI.
* **Proposed Changes**: Remove the "Open Work Backfill" section, both text fields, their bindings, the Backfill Now button and the error/status state that only served backfill. Add a read-only scope line derived from `githubUsername` and the last Open Work status. Keep the Google, PAT, projects, agent and terminal sections.

#### 14. `Sources/DispatchApp/Views/OnboardingView.swift` (Modify)

* **Type / Scope**: First-run copy.
* **Proposed Changes**: Rename the GitHub card from "GitHub Notifications" to "GitHub Open Work" and describe the import scope. Keep the connected test on the PAT. No new flow.

#### 15. `Sources/DispatchApp/Models/TriageItem.swift` (Modify)

* **Type / Scope**: Shared model cleanup.
* **Proposed Changes**: Remove the `.gitHubIssue`, `.gitHubPullRequest` and `.gitHubNotification` cases from `TriageKind`, `ReviewStatus`, `CheckSuiteStatus`, `isBackfillDerived`, and `canonicalKey` if it is no longer referenced. Keep `TriageSource`, `TriageItem`, `GitHubIssueDetail`, `GitHubComment`, `TerminalApp`, `AgentCLI` and the dispatch payload. Old snapshots containing GitHub kinds are ignored by the tolerant `SnapshotData` decoder.

#### 16. `Sources/DispatchApp/Views/Components/RecycledWKWebView.swift` (No change)

* Listed to confirm it is untouched. Gmail rendering does not change.

#### 17. `Tests/DispatchAppTests/GitHubBackfillTests.swift` (Delete)

* **Type / Scope**: Obsolete tests.
* **Proposed Changes**: Delete. Its assertions cover `fetchOpenIssuesAndPullRequests`, `setGitHubBackfill`, merge deduplication and tombstone resurrection, all of which are removed. Its useful fixtures move to the new Open Work tests.

#### 18. `Tests/DispatchAppTests/OpenWorkFetchTests.swift` (Create)

* **Type / Scope**: Service tests with a URL protocol stub.
* **Proposed Changes**: Cover one-page and multi-page responses, `total_count` mapping, truncation at the 400-item cap, duplicate keys across pages, 401/403/5xx/decoding errors, and the exact query string. Assert that no per-repository request is made.

#### 19. `Tests/DispatchAppTests/OpenWorkStoreTests.swift` (Create)

* **Type / Scope**: Store tests.
* **Proposed Changes**: Cover success replacement, failure retaining items and `lastSuccess`, stale status, selection preservation and nearest-neighbour fallback, repository grouping and sorting, hide/unhide/undo, hidden-key persistence across a fresh store, the 1,000-key cap, and the invariant that `TriageStore.unreadCount(for: .gmail)` is unaffected by Open Work.

#### 20. `Tests/DispatchAppTests/OpenWorkCoordinatorTests.swift` (Create)

* **Type / Scope**: Scheduler tests.
* **Proposed Changes**: With the injected interval and sleeper, assert one refresh per interval, no overlap when a manual refresh arrives during a run, a wake-triggered refresh, a network-unavailable skip, and that a failed run publishes `.stale` with no items while keeping `lastSuccess`.

#### 21. `Tests/DispatchAppTests/TriageStoreTests.swift` (Modify)

* **Type / Scope**: Gmail and snapshot tests.
* **Proposed Changes**: Remove GitHub filter, backfill, merge and notification tests. Keep Gmail action and unread tests. Add a fixture that decodes a pre-change snapshot containing `gitHubItems` and `dismissedGitHubKeys`, and assert the Gmail items survive.

#### 22. `Tests/DispatchAppTests/SyncCoordinatorTests.swift` (Modify)

* **Type / Scope**: Coordinator tests.
* **Proposed Changes**: Remove the GitHub assigned-issue and ETag tests. Keep Gmail bootstrap, history, sleep/wake and network tests. If any GitHub stub remains, point it at the Open Work search endpoint.

#### 23. `README.md` (Modify)

* **Type / Scope**: Product documentation.
* **Proposed Changes**: Replace the GitHub notifications/backfill description with Open Work: involvement scope, 15-minute refresh, no unread state, no repository configuration, the review-requested limitation, the 400-item ceiling, and the classic versus fine-grained token behavior. Keep the existing install and Gatekeeper notes untouched.

### Verification Plan

* **Compilation/Build**: `swift build` and `swift build -c release`.
* **Unit Tests**: `swift test --no-parallel`, matching CI.
* **Static Analysis & Linting**: No linter is configured. Use a clean `swift build` with no warnings from the touched files.
* **Test Coverage Requirement**: Every invariant in the Technical Plan maps to at least one assertion in the new or updated test files.
* **E2E/Integration**: Manual run against the maintainer's account (52 repositories, 89 open items). Verify one search request populates the list; a simulated 403 keeps rows and shows stale; closing an issue upstream removes it on the next success; hide plus relaunch keeps it hidden; offline launch shows the never-imported state rather than "All Caught Up".
* **Rollback Check**: Load a snapshot written by the current release in the new build and confirm Gmail items and dismissal keys survive; then run the current release against a snapshot written by the new build and confirm it still opens.
