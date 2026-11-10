# GitHub Open Work Import

* **Author:** Dispatch maintainer
* **Date:** 2026-11-09

## Overview

Dispatch's GitHub workspace currently combines two feeds: a live search for open issues assigned to the authenticated user, polled every 45 seconds, and a "backfill" that imports open issues and pull requests involving the user, refreshed every 15 minutes and merged into the same list. The merge is the source of most defects. Imported work is never unread, is deduplicated through a key derived from the item ID, and disappears from the UI when a fetch fails because the whole set is replaced by whatever the failed run returned.

The proposed direction is to stop merging and stop running two feeds. The GitHub workspace becomes **Open Work**: every open issue and pull request involving the authenticated user that the PAT can read, fetched in one query, held in memory, and refreshed every 15 minutes while the app runs. It has its own selection, counts, and status: last attempt, last success, item count, truncation, and the error that stopped it. A failed refresh keeps the previous set and marks it stale. A successful refresh drops closed and merged items. Nothing in Open Work is counted as unread.

The live assigned-issue feed is a subset of this query and is removed, along with its 45-second poller, its unread badge, and the broken GitHub smart filters. Scope is resolved from the token, not from hand-maintained lists: authored, assigned, mentioned, commented on, or subscribed. Review-requested pull requests that involve the user in no other way are accepted as out of scope for this version.

## Analysis

Six independent Goldfish lenses reviewed the concept against the code: design, codebase, zoom-out, comprehension, implementation readiness, and structural. All six completed. Their findings overlap on five points.

### 1. The merge model cannot support a separate view

The current store keeps imported work inside `gitHubItems` and merges it with the live feed on every poll (`TriageStore.swift:187-272`). Several behaviours branch on `isBackfillDerived`, which is inferred from an ID prefix (`TriageItem.swift:97-99`). That prefix is produced in one place (`GitHubService.swift:514-518`) and differs from the live feed's ID format (`GitHubService.swift:189`). Changing either format silently reclassifies items and changes how they are retained, dismissed, and counted.

Two tombstone stores exist for the same concept. `dismissedGitHubKeys` lives in the snapshot and is pruned by intersecting with the latest fetch result (`TriageStore.swift:219`). `dismissedGitHubIssueIDs` lives in UserDefaults and is capped by nondeterministic Set iteration (`TriageStore.swift:163-172`). The two do not apply to each other, so an item dismissed through one path can return through the other.

The snapshot decoder has no schema version and decodes into non-optional fields (`TriageStore.swift:28-48`, `309-327`). Adding a stored field to `TriageItem` would make every existing snapshot fail to decode, and the failure path leaves empty arrays; the next quit overwrites the old file. This redesign avoids the problem by not changing `TriageItem`.

The documented cross-feed identity rule is also wrong. `.gitHubNotification` keys on the thread ID (`TriageItem.swift:88-89`), while imported items key on repository and number (`:84-87`). The two can never deduplicate. It happens not to matter today because no production code builds `.gitHubNotification`; the only references are tests. That dead path should be deleted, not extended.

**Conclusion:** the imported set needs its own collection, its own identity (`owner/repo#number` plus kind), and stored provenance. `isBackfillDerived`, `mergedGitHubItems`, and the two tombstone sets are removed rather than reused.

### 2. The scope promise is wider than the query

`/issues?filter=all&state=open` returns issues and pull requests the user created, was assigned, was mentioned in, or subscribed to (`GitHubService.swift:241-248`). It does not return review-requested pull requests unless the user is also subscribed, and it does not return every open item in every repository the token can read. The label "everything you are involved with" is close; "all work within PAT access" is not. The product copy must name the limit.

The current Settings UI offers two free-text lists, for owners and repositories, and runs them as a union (`GitHubService.swift:250-288`). Filling both imports everything owned by the owners, which is not what the copy says ("Narrow the backfill to specific repositories", `SettingsView.swift:184`). Malformed lines are silently dropped by normalization (`GitHubService.swift:292-332`) while remaining on screen. Adding your own account as an owner imports every open issue across all your repositories, not your work, and then truncates at 500. The user decided these fields disappear entirely.

Fine-grained tokens and SSO-protected organizations narrow the accessible set further. The Settings copy still recommends a classic token with `repo` and `notifications` scopes (`SettingsView.swift:115-124`), which is a different promise from "within PAT access". The copy must match what the involvement query actually returns.

**Conclusion:** one involvement query with no owner or repository configuration. The view states the scope in one sentence and does not imply that every repository's backlog is included.

### 3. Failure, truncation, and freshness are all invisible

Three layers swallow errors: each per-repo or per-owner source uses `try?` and returns an empty array (`GitHubService.swift:255-279`), `performGitHubBackfill` catches everything and does nothing (`SyncCoordinator.swift:161-164`), and `syncGitHub` has an empty catch (`SyncCoordinator.swift:288-290`). A partial result then replaces the entire visible set (`TriageStore.swift:216-224`). One 403 or 404 deletes that source's items from the UI and prunes its tombstones, so previously dismissed items come back on the next successful run.

The caps are silent. The default is three pages per source (`GitHubService.swift:236`), which is 300 items. The store truncates to 500 by array position (`TriageStore.swift:64-70`, `198-202`), and search results are capped at 1,000 by GitHub. The search payload's `total_count` is decoded and discarded (`GitHubService.swift:432-434`). There is no way for the user to tell "there are 89 items" from "there were more and we dropped them".

There is no status surface at all. `isLoading` is declared and read but never set true (`TriageStore.swift:77`, `SidebarView.swift:89`), so the sidebar always shows a green "Live" dot. `hasCompletedGitHubBackfill` and `isBackfilling` are actor-private and not persisted (`SyncCoordinator.swift:32-33`). "Backfill Now" posts a `NotificationCenter` event (`SettingsView.swift:189-194`), and the only listener is inside the main window's scene (`DispatchApp.swift:25-37`). Close the main window, open Settings, and the button does nothing. A second click while a run is active also returns silently (`SyncCoordinator.swift:149`).

**Conclusion:** replace the callback with a status object: last attempt, last success, running state, matched count, shown count, truncation flag, and the error. Replace the set only on a complete run. Keep the previous set and mark it stale when a run fails. Call the coordinator directly instead of broadcasting through NotificationCenter.

### 4. The UI treats a backlog as an inbox

Imported items arrive read (`GitHubService.swift:524`), so the GitHub unread badge shows zero while hundreds of rows exist (`TriageStore.swift:176-183`). The empty state says "All Caught Up" whether the fetch returned nothing or failed (`TriageStreamView.swift:41-58`). The smart filters cannot match imported pull requests because `reviewStatus` and `ciStatus` are hardcoded (`GitHubService.swift:499-506`). Archive and Trash on an imported item only hide it locally (`TriageStore.swift:356-360`, `415-419`), but the detail pane labels them as notification actions (`DetailPaneView.swift:245-260`), and there is no undo or hidden list. The 15-minute refresh reselects the first item whenever the selected one disappears (`TriageStore.swift:226-228`), so reading is interrupted by housekeeping.

The live assigned feed makes this worse. It creates items as unread (`GitHubService.swift:195`), re-emits them every 45 seconds, and preserves local read state only for imported items (`TriageStore.swift:262-265`). Pressing `u` on an assigned issue is reverted within one poll, and that item is counted in the badge.

**Conclusion:** GitHub becomes a backlog view and should behave like one: never unread, grouped by repository, with a visible last-success time, undoable local hiding, and a selection that survives refresh. Notification verbs and unread controls apply to Gmail only.

### 5. The live assigned feed duplicates the import

The live feed is `is:issue is:open assignee:@me` (`GitHubService.swift:115`). That is a subset of an involvement query. Today the app runs two pollers, keeps two identity conventions, and maintains two dismissal stores for one dataset. The user decided to fold the assigned feed into Open Work. `fetchAssignedIssues`, `lastGitHubETag`, `GitHubFilter`, and the sidebar filter section are removed. The GitHub workspace shows only Open Work.

The only loss is the unread badge and the 45-second poll for assigned issues. The badge was already wrong for this data, and a backlog does not need 45-second freshness. The sidebar row shows a neutral open-item count instead of an unread count.

### 6. The product challenge

The zoom-out lens asked whether a backlog belongs in a triage client at all. The strongest counter-proposal was an on-demand query view: one involvement search when the view opens, held in memory, refreshed on demand and every 15 minutes while the app runs, with no merge, no tombstones, no snapshot, and no 500-item cap. The user chose that shape for the first version. It satisfies every stated decision with far less state and removes the schema-migration risk. Persistence is deferred until there is a reason to pay for it.

The remaining product risk is honest: with the assigned feed gone, Dispatch's GitHub side is a read-only browser of open work. That is a smaller claim than "triage", and the README and onboarding must say so. If users need an action queue rather than a backlog, relationship filters are the next feature, not a reason to rebuild this one.

### Adjacent defects, out of scope

The published build is ad-hoc signed, has no Team ID, is rejected by `spctl`, and has no stapled notarization ticket. Every re-download is a different code identity, which is why macOS keeps asking for approval and why Keychain access can fail across updates. Separately, the Google refresh token is stored but `refreshGoogleToken` is never called, so Gmail auth dies after about an hour. Both are release and authentication fixes. They are recorded here because they affect trust in the same screens, not because this brief should solve them.

## Goals vs. Non-Goals

**In-scope goals**

- Import every open issue and pull request involving the authenticated user that the PAT can read: authored, assigned, mentioned, commented on, or subscribed.
- Refresh the full set every 15 minutes while the app runs and when the view opens, replace it only after a complete run, and keep the previous set marked stale after a failure.
- Show last attempt, last success, matched count, shown count, truncation, and the error in the Open Work header.
- Make the GitHub workspace Open Work: grouped by repository, never counted as unread, with undoable "Hide from Open Work" and "Open on GitHub".
- Remove the live assigned-issue feed, its ETag polling, the GitHub smart filters, the merge engine, the ID-prefix provenance check, and both tombstone stores.
- Remove the owner and repository fields from Settings. Show a read-only scope sentence and the last import status instead.
- Keep "Hide from Open Work" keys across relaunch in UserDefaults, without persisting the items themselves.

**Out-of-scope non-goals**

- Changing GitHub state. Dispatch will not close issues, merge pull requests, or mark notifications read from Open Work.
- Review-requested pull requests that involve the user in no other way. Accepted limitation, stated in the copy.
- Importing every open item in every accessible repository, including other people's backlog.
- Fetching CI or review metadata for imported pull requests. Unknown values stay unknown until a separate feature adds them.
- Persisting imported items across relaunch in the first version.
- Gmail behavior, notification-feed redesign, multi-account support, and macOS signing/notarization.
- Guaranteed completeness above the API limit. The view must disclose truncation instead.

## Alternatives Weighed

**A. Keep the merged feed and add a status row.** Rejected. The unread count, selection, filters, and dismissal semantics all assume one list. A status row does not fix the invariant "imported work is never unread" while the live feed re-marks assigned items unread every 45 seconds.

**B. Add an Open Work filter to the existing list.** Rejected for the same reason. The list is ordered by merge position, not by repository, and the 500-item cap truncates by position.

**C. Separate Open Work collection with persistence.** Deferred. It requires a schema version and a migration path because the current snapshot decoder destroys data on any model change. The user chose the in-memory version first.

**D. On-demand, in-memory Open Work collection (chosen).** One query, held in memory, refreshed while the app runs. Removes snapshot migration, tombstone persistence, and cold-start ordering risk. The cost is a network wait when the view first opens and the loss of hidden-item continuity unless hide keys are stored separately, which they are.

**E. Enumerate every accessible repository and fetch its open issues.** Rejected. It imports other people's backlog, scales with repository count rather than with the user's work, and multiplies rate-limit exposure. The user's own account has 52 repositories and 89 open items, so the current caps happen to fit; a user in a large organization is the failure case.

**F. Delete the feature and use GitHub saved views.** Rejected by the stated goal. It remains the fallback if Open Work cannot name a task it does better than `github.com/issues`.

**GraphQL versus REST.** A GraphQL search can return `totalCount` and page info in one query, but fine-grained PAT support and SSO authorization must be verified before relying on it. The REST search endpoint also returns `total_count` and works with the classic token the app already documents. Use REST first; do not add a second protocol for this feature.

## Key Decisions & Staging for Next Steps

### Decisions

1. **Scope.** Involvement only: authored, assigned, mentioned, commented, subscribed. No owner or repository configuration. No separate review-requested query. The view states that review-requested items are included only when they also involve the user.
2. **State.** A dedicated `OpenWorkStore` owns imported items and status. Provenance and relationship are stored properties, not ID prefixes. Identity is `owner/repo#number` plus issue or pull request.
3. **Refresh.** Every 15 minutes while the app runs, plus on view open. Replace only on a complete run. On failure, keep the old set, leave `lastSuccessAt` unchanged, and show the error. Scheduling is independent of `pollCycleCount` modulo arithmetic so sleep and manual runs do not drift it.
4. **Caps.** Paginate to exhaustion or to a hard product cap, and show `matched` versus `shown` plus a truncation banner. Do not truncate by array position.
5. **Semantics.** Imported items are never unread. The GitHub sidebar row shows a neutral open-item count, not an unread badge. `u` does nothing. `e` hides the item from Open Work with an undo toast; `#` does nothing. The primary row action is "Open on GitHub". Hidden keys persist in UserDefaults.
6. **Settings.** Delete the two free-text lists and the Backfill Now button. Show a read-only scope sentence: "Imports every open issue and PR involving @login that this token can read." Status and Refresh live in the Open Work header.
7. **Live feed.** Remove the assigned-issue search, its ETag, its poller, the GitHub smart filters, and GitHub unread counts. The GitHub workspace is Open Work.
8. **Persistence.** No item snapshot in this version. Keep `SnapshotData.gitHubItems` decodable so old snapshots still load, but stop writing GitHub items into it. Gmail persistence is unchanged.

### Staging

| Stage | Work | Acceptance check |
| --- | --- | --- |
| 0 | Keep the old snapshot format decodable; stop writing GitHub items into it | A pre-change `snapshot.json` fixture loads with Gmail items and dismissal keys intact |
| 1 | Add `OpenWorkStore` and a fetch that returns items plus a status object | A fixture with a failed page keeps the previous items and reports one error |
| 2 | Enforce refresh integrity: complete-only replacement, stale-on-failure, truncation flag | A failed refresh never removes rows; a successful refresh drops closed and merged items |
| 3 | Build the Open Work view: repository grouping, counts, last success, error row, undoable hide | Opening, refreshing, hiding, and undoing all work without touching `gitHubItems` |
| 4 | Remove the live feed, merge engine, ID-prefix provenance, tombstone stores, GitHub filters, and Settings fields | No code reads `isBackfillDerived`; no GitHub unread badge; no owner/repo input |
| 5 | Add tests for the invariants and update README and onboarding copy | Unread count is unchanged by 300 imported items; a closed-then-reopened item stays hidden until the hide is cleared |

### Invariants to pin with tests

1. An imported item is never counted by `unreadCount` and never appears in the Gmail feed, even when both sources return records for the same repository.
2. A failed refresh never mutates the visible set and always updates `lastAttempt` without touching `lastSuccess`.
3. Closed and merged items disappear on the next successful refresh; a failed refresh leaves them visible and marked stale.
4. Hiding is idempotent, survives relaunch through UserDefaults, and is respected by every fetch path.
5. An old snapshot round-trips without losing the Gmail cache.
6. Item classification never depends on parsing an ID string.
7. The GitHub sidebar count equals the number of visible Open Work items, not the number of unread items.

### Open decisions

- Do fine-grained tokens and SSO organizations need explicit support, and should the copy say so?
- What should the view do above 1,000 matched items: hard cap with a banner, or a narrower default filter?
- Are relationship groups (Assigned, Authored, Mentioned) worth the extra queries needed to know why each item is in scope? Deferred for the first version.
