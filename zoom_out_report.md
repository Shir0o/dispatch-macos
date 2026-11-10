# Zoom Out Re-review — `docs/designs/github_open_work.md` (Round 3)

**Verdict: still not handoff-ready.** The round-2 contracts were mostly fixed in substance — pagination, attempt stamping, single-flight, the slice order, and the rollback claim are now true. Four blockers remain, and two of them are new consequences of the revision. The document still reads as a good architecture with a contradictory interface contract.

## Blockers

### B1. Success and “complete” are still conflated, and the truncation contract is unreachable — lines 13, 37, 39, 158, 190, 221–224

Line 13 promises “A refresh replaces the list **only after a complete run**”; line 190 says “If not complete, **replace** the visible list but do not prune hidden keys.” Those are opposite.

Worse, line 190 puts the updates to `lastSuccess`, `matchedCount` and `truncated` inside the `complete` branch, and `complete` requires `!truncated` (line 179). Therefore `truncated` can never become true, so Goal 5’s truncation notice (line 39) and the “X fetched · Y matched (capped)” line (line 224) can never render. For a user above 400 matches, `lastSuccess` never advances either, so the header (line 222) permanently reports “refreshed 3h ago” over data fetched 30 seconds ago. The same users never get a persisted summary, since line 158 hydrates from the same complete-only write.

Fix: update `lastSuccess`, `matchedCount` and `truncated` on **any** successful fetch; keep pruning hidden keys on `complete` only; if a distinct “capped” freshness claim is wanted, add `lastComplete` explicitly. Then fix line 13.

### B2. The hidden-key migration lands after the store has loaded — lines 106–115, 158, 193, 212–213, 253, 411, 480

Item 7 creates `OpenWorkStore` at step 2; `TriageStore.loadSnapshot()` runs at step 3 (`DispatchApp.swift:74`). Item 19 seeds `dispatch.openWorkHiddenKeys` **inside `loadSnapshot`**. The store reads that key in `init` (line 212), so on upgrade it loads an empty set, then the first `hide()` persists that empty set and destroys the migration. The hidden items reappear once, and the old hides are gone permanently.

The PAT migration has the same shape of problem in miniature: it is in item 7, ahead of the snapshot load, and `PreferencesStore` still owns the key until Slice 5.

Fix: run one migration function in the composition root **before** constructing the store, or pass the legacy sets into `OpenWorkStore.init` and merge-and-persist there. Line 253’s “before deleting either” is not enough; it must also be before the store reads.

### B3. The store is created after `body`, but injected into a window built by `body` — lines 105–115, 206, 411, 426, 456

Item 7 says “Create GitHubService first, then `OpenWorkStore(fetchAction:defaults:now:)`” inside `setupServicesAndSync()`, which runs from `.onAppear`, and then “Inject the store into the window, Settings and Onboarding.” The window and Settings scenes are constructed in `body` (`DispatchApp.swift:14,42`) before `onAppear`; item 10 and item 15 require `@Environment(OpenWorkStore.self)`, which needs a non-optional value already in the environment.

The mandated `fetchAction` initializer parameter makes the alternative harder, not easier: `GitHubService` needs `AuthService`, and SwiftUI property initializers cannot reference another `@State` (`DispatchApp.swift:7-10`). No construction is specified that satisfies both “init parameter” (A5) and “create it at launch”. Slice 3 has no compilable path as written.

Fix: name the ownership explicitly — either a `@State` store built from a lazily resolving closure, or `@State private var openWorkStore: OpenWorkStore?` plus a custom `EnvironmentKey` that the four views unwrap.

### B4. The header contract asks for per-error actions, but the status carries only a string — lines 78, 148–158, 191, 225

`OpenWorkStatus` exposes `errorText: String?` only. The view must choose “Update token” for 401, “Retry at HH:MM” for 403, and “Retry” otherwise (lines 78, 225). String-matching `errorText` is not a contract, and `OpenWorkFetchError` is discarded inside the store.

Separately, four of the seven cases have no copy or action at all: `.notConfigured`, `.notFound`, `.decoding`, and `.forbidden(resetAt: nil)`. The last is the realistic case for a fine-grained token without access — the very v1 limitation the document documents — and it would render “Retry at nil”.

Fix: store `error: OpenWorkFetchError?` (or a `recovery` enum) and give every case one row in the state table.

## Major Findings

### M1. The first fetch no longer has a gate — lines 37, 188, 195–200, 416

`refreshIfDue()` refreshes on `!hasFetchedThisLaunch` with no “workspace opened” condition. The 45-second loop calls it, so Open Work fetches within 45 s of launch whether or not GitHub was ever opened. That contradicts Goal 3 (“on the first open … in each launch”), CUJ 5’s premise, and item 8’s explicit assertion “no refresh before the first open”. It also shows an offline error banner before the user visits the workspace. Pick one and delete the other.

### M2. `clear()` destroys hides — lines 90, 192, 210, 242

Clearing the PAT resets hidden keys. Goal 8 says a hide survives “until the user restores it individually or chooses Restore all hidden”; disconnect is a third, undocumented path. Hidden keys are repository names and numbers (line 332), not credentials, so they do not need clearing. Keep them, and clear `lastHiddenKey` explicitly.

### M3. The PAT migration instructions contradict themselves and regress Slice 3 — lines 240, 368, 401, 411, 441

Item 7 says “keep the defaults key until [Settings/Onboarding] land”, then in the same paragraph says to delete it. Deleting at launch, with items 10–11 ordered after item 7 and `isFirstLaunchEmptyState` still reading `preferencesStore.githubPAT` (`MainSplitView.swift:37`) until Slice 4, means an existing user relaunches into onboarding mid-plan. Line 368 still says the switch happens “within Slice 5”, which is where it used to be. Land the config check first, then delete the key.

### M4. `snapshotLoadFailed` is a permanent dead end — lines 251–252, 336

A corrupt file suppresses every save “for that launch”, but the file is never rewritten, so every subsequent launch fails identically. The user’s Gmail state stops persisting forever with no path out. Add a one-time rename (`snapshot.corrupt-<date>.json`), start clean, and report it.

## Nits

* `authorLogin: String` and `webURL: URL` are non-optional but `user` and `html_url` are fallible in the payload; define fallback-or-skip.
* `restoreAllHidden()` clears the whole set, while the label counts keys present in `allItems` (lines 210–211, 229). Label it “Clear all hidden keys” or restore only the counted ones.
* `matchedCount`/`truncated` exist both on the store and on `OpenWorkStatus`, and lines 158 and 193 both claim hydration in `init`. Say it once.
* Line 416 says “seven-argument coordinator constructions”; the tests contain seven **two**-argument constructions (`SyncCoordinatorTests.swift:224` etc.).
* Item 19 lists strip prefixes as `gh:`, `gh:issue:`, `gh:pr:` (line 480). Longest-first is required, and snapshot keys are `gh:owner/repo#n` from `canonicalKey` (`TriageItem.swift:80-91`) while the defaults set is mostly unprefixed ids.
* Two payload builders remain (`MainSplitView.dispatchCurrentItem`, `DetailPaneView.dispatchToAgent`), both now “fetch detail, fall back to title”. Choose one.
* `TriageStore.selectedItem`’s `?? gitHubItems.first` (`:144`) and `activeItems`’s `.gitHub` branch (`:130-137`) are not named in item 19’s removal list.
* The migration writes `UserDefaults.standard`, while `OpenWorkStore` takes an injected `defaults`; the “old hidden keys seed the new set” test needs one suite.

## Verified fixed (not re-raised)

* Fetch contract: own pagination, throw on any non-2xx, wrapper kept with `total_count`, 404 not empty success, exact-400 case correct.
* Clock: attempt stamped before the fetch, first-of-launch on `hasFetchedThisLaunch`, one `refreshTask`, injected `now`.
* Slices: test deletion precedes method removal; views precede model deletion; full-suite gate.
* Rollback: `SnapshotData.dismissedGitHubKeys` is already optional and `gitHubItems: []` decodes in the old build — the claim is now true.

## Open Questions

1. Does Open Work fetch at launch or only after the first GitHub open? The document says both.
2. Does a hide survive “Clear PAT”? The document says both.
3. For a user above 400 matches, is “last refresh” the last complete run or the last successful one? The header and the store disagree.
