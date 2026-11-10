# Goldfish Review Report — Critic Stage (Round 3)

**Target:** `docs/designs/github_open_work.md` (FeatureRange 1–365)

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-design` | completed |
| `egm-structural` | completed |
| `egm-style` | completed |

## Verdict

The architecture is coherent, but the user-facing contract still has dead ends and the refresh contract still contradicts itself. The same four blockers from the other Stage 5/6 reviews recur: complete-versus-success, the hidden-key migration order, store construction before `body`, and error identity. The design also has a one-way hide, a recovery button that leads to a screen with no token field, and missing loading/disconnected states.

## Blocker Findings

### B1. The replace/prune contract contradicts itself, and `truncated` can never reach the UI — Severity: Blocker

* **Reviewer Lens:** design, structural, style
* **Affected Scope:** lines 13, 37, 144, 178–179, 190–191, 221–224
* **Discrepancy:** Lines 13 and 37 say the list is replaced only after a complete run; line 190 replaces on an incomplete run. More seriously, `lastSuccess`, `matchedCount` and `truncated` are updated only inside the `complete` branch, and `complete` requires `!truncated`. A user above 400 matches can never set `truncated`, advance `lastSuccess`, or persist a matched count, so the truncation notice and header cannot render.
* **Rationale & Recommendation:** One `applySuccess(result)` must always replace `allItems` and update `lastSuccess`, `matchedCount` and `truncated`. Use `complete` only to gate closed-item removal and hidden-key pruning. Rewrite lines 13 and 37 to match.

### B2. The first fetch does not wait for the first workspace open — Severity: Blocker

* **Reviewer Lens:** comprehension, structural, style
* **Affected Scope:** lines 37, 72, 187–188, 197–199
* **Discrepancy:** `refreshIfDue()` fires on `!hasFetchedThisLaunch` with no workspace condition, and the 45-second loop calls it from launch. Open Work therefore fetches before the user opens GitHub, contradicting Goal 3, CUJ 1 and item 8’s “no refresh before the first open” test. The open-hook caller is still “`MainSplitView.onChange` or `OpenWorkView.task`.”
* **Rationale & Recommendation:** Add an explicit `hasOpenedOpenWork` gate that the loop respects, or delete “first open” from the goal and CUJ. Name one caller and remove the “or.”

### B3. The hidden-key migration runs after the store has read the key — Severity: Blocker

* **Reviewer Lens:** design, structural, comprehension
* **Affected Scope:** lines 207–213, 251–253, 392, 411, 480
* **Discrepancy:** Item 7 creates the store before `TriageStore.loadSnapshot()`, and the store reads `dispatch.openWorkHiddenKeys` in `init`. The seed happens inside `loadSnapshot` later. On upgrade the store loads an empty set; the first hide persists it over the migration, destroying the old hides.
* **Rationale & Recommendation:** Run one `migrateLegacyHiddenKeys()` before constructing the store, or pass the legacy sets into `OpenWorkStore.init` and merge before the first read. Order the old-key deletion after the seed.

### B4. The store has no construction path that precedes `body` — Severity: Blocker

* **Reviewer Lens:** design, structural, comprehension
* **Affected Scope:** lines 105–115, 217–218, 234, 242, 411
* **Discrepancy:** The store is created in `setupServicesAndSync()` on appear, then injected into scenes built by `body`. `@Environment(OpenWorkStore.self)` needs a value before the first body pass. The `fetchAction` initializer parameter and `GitHubService`’s `AuthService` dependency make a property initializer non-trivial, and no owner is named.
* **Rationale & Recommendation:** Pick one: a root model built in `DispatchApp.init`, or an optional `@State` store with a custom `EnvironmentKey` that unwraps. State it in the Technical Plan, not only in the slice items.

### B5. Error identity and recovery are undefined — Severity: Blocker

* **Reviewer Lens:** design, structural, style
* **Affected Scope:** lines 78, 148–158, 191, 225–226
* **Discrepancy:** `OpenWorkStatus` carries only `errorText`, but the view must choose “Update token” for 401, “Retry at HH:MM” for 403, and Retry otherwise. `.notConfigured`, `.notFound`, `.decoding` and `.forbidden(resetAt: nil)` have no copy or action; the nil case is the realistic fine-grained-token failure and would render “Retry at nil.”
* **Rationale & Recommendation:** Store `error: OpenWorkFetchError?` (or a recovery enum) on the status and define one copy/action row per case. Derive `errorText` from it.

### B6. Hidden work has no individual inverse after the banner — Severity: Blocker

* **Reviewer Lens:** design, style
* **Affected Scope:** lines 90, 210–211, 226, 229
* **Discrepancy:** Goal 8 and CUJ 4 promise the item stays hidden until restored individually or via Restore all. Individual restore is only “from the row’s context menu,” but a hidden item has no row and no hidden-items list exists. `unhide(key:)` has no reachable caller after 5–8 seconds. `restoreAllHidden()` clears the whole set, including keys not counted in “(N).”
* **Rationale & Recommendation:** Add a Hidden-items section or a persistent per-key undo affordance. Restrict Restore all to the counted keys or label it “Clear all hidden keys.”

### B7. “Update token” leads to a Settings screen with no token field — Severity: Blocker

* **Reviewer Lens:** design
* **Affected Scope:** lines 78, 233, 242; `SettingsView.swift:112-142`
* **Discrepancy:** The 401 action opens Settings, but the Settings spec says it shows a read-only scope sentence and Clear PAT only. The existing SecureField and Validate & Save controls are not mentioned as retained.
* **Rationale & Recommendation:** Specify Settings’ connected and disconnected variants, keep the token field plus Validate & Save, and have “Update token” open Settings with the field focused.

### B8. The state table omits loading, disconnected and the sidebar’s unknown state — Severity: Blocker

* **Reviewer Lens:** design, structural
* **Affected Scope:** lines 72, 188, 218, 221–226, 242
* **Discrepancy:** CUJ 1 requires a loading state, but the empty states are only not-loaded, failure, ready-empty and all-hidden. With `isConfigured == false`, Refresh cannot succeed yet is offered. The sidebar renders `visibleCount` as 0 on cold start and when all items are hidden, contradicting the header.
* **Rationale & Recommendation:** Define one state table over `phase`, `isConfigured` and item count, with header copy, empty copy and CTA. Include “Loading Open Work…”, “GitHub isn’t connected” + Connect, and a sidebar rule that never presents 0 as fact when unloaded or fully hidden.

### B9. The PAT is kept and deleted in the same paragraph, and a later slice still reads it — Severity: Blocker

* **Reviewer Lens:** comprehension, style, zoom-out
* **Affected Scope:** lines 240, 368, 411, 441, 470
* **Discrepancy:** Item 7 says keep the defaults key until Settings/Onboarding land, then deletes it in the same item. Items 10–11 are in Slice 3, but the plan preamble still says Slice 5. Item 12 in Slice 4 still replaces `isFirstLaunchEmptyState`’s `preferencesStore.githubPAT` read, so an existing user can relaunch into onboarding between deletion and item 12.
* **Rationale & Recommendation:** Land the configuration check first, then delete the key. State one order and remove the stale “within Slice 5” sentence.

### B10. Clearing the PAT destroys hides and does not cancel an in-flight refresh — Severity: Blocker

* **Reviewer Lens:** design, structural
* **Affected Scope:** lines 192, 210, 242; Goal 8 line 42
* **Discrepancy:** `clear()` resets hidden keys, contradicting the promise that a hide survives until restored. It also neither cancels nor invalidates `refreshTask`, so an in-flight fetch can repopulate the disconnected workspace.
* **Rationale & Recommendation:** Keep `hiddenKeys` across disconnect; split `disconnect()` from `resetLocalState()`. Cancel `refreshTask` and add a generation token so an old result is discarded.

### B11. Persisted truncation has no coherent cold-start display — Severity: Blocker

* **Reviewer Lens:** design
* **Affected Scope:** lines 158, 190, 224
* **Discrepancy:** `truncated` and `matchedCount` hydrate, but `fetchedCount` is not persisted. On relaunch the truncation line can only render “0 fetched · 1,000 matched (capped)”; gating it on items hides the capped state until a new fetch. This compounds B1.
* **Rationale & Recommendation:** Persist `fetchedCount` or `lastComplete`, or write cold-start copy that says “1,000+ matched at last refresh; showing nothing until refresh.” Define the line’s visibility predicate.

## Major Findings

* **M1. `e` changes meaning and three keys vanish silently.** Gmail’s `e` archives remotely; Open Work’s hides locally. `u`, `s`, `#` do nothing with no feedback. Label the shortcut or use `h`; show “Not available in Open Work” instead of swallowing.
* **M2. The header is overloaded.** Four counts, Refresh, a menu and a 110-character scope sentence in a 280-point pane. Reduce to “Showing 400 of 1,000+ · 12 hidden” and move the scope into an info popover.
* **M3. Required scope disclosures are missing from the copy.** The sentence names only the positive involvement set, and the empty state is false for review requests and SSO-blocked organizations. Use “Open work involving @login that this token can read; review requests and subscriptions are not included.”
* **M4. Bulk actions have no confirmation.** Restore all and Clear PAT destroy curation irreversibly. Confirm both with counts; keep hides across Clear PAT.
* **M5. Dispatch degrades silently and has no unconfigured state.** Title-only fallback for an agent is not consent. Offer “Send title only” / Cancel, and define the disabled state with no agent or terminal.
* **M6. “What did it bring in” is still unanswered.** The Problem asks it; Success drops it; no non-goal excludes a new-item signal. Add “N new since last refresh” or declare it a non-goal and remove the question.
* **M7. PAT write failure keeps an unreadable value.** The provider reads the Keychain only, so retaining the defaults value is not a recovery path. Keep the fallback until verified, or treat failure as “reconnect required.”
* **M8. Token-provider errors escape the mapping.** `AuthError` from `readKeychainValue` is not mapped to `OpenWorkFetchError`; a locked Keychain throws an unclassified error. Map at the service boundary.
* **M9. Two payload builders remain.** `MainSplitView.dispatchCurrentItem` and `DetailPaneView.dispatchToAgent` produce different prompts. Use one `dispatch(openWorkItem:preloadedDetail:)`.
* **M10. `snapshotLoadFailed` has no exit.** Rename the corrupt file once, start clean, and report it.
* **M11. Migration sources and prefixes disagree.** One source is named in one place, two in another; prefixes differ; the old key deletion is unowned. Consolidate.
* **M12. Offline state has no precedence.** “Not loaded” and “Could not load” are both defined for the same state. Pick one order.

## Nit Findings

- Restore-all label counts `allItems` keys but clears the persisted set.
- Two launch flags (`hasFetchedThisLaunch`, `lastAttempt == nil`) can drift.
- Two UserDefaults domains in tests versus production.
- `selectedItem`’s `gitHubItems` fallback and `activeItems`’ `.gitHub` branch are not named in item 19.
- `matchedCount`/`truncated` exist on both result and status; hydrate once.
- Non-optional `authorLogin`/`webURL` need skip-or-fallback rules.
- “One component is new; four change role” is arithmetically wrong; three change role.
- Risk text says relationship-reason items are excluded; they still appear.
- “live search” vs “live feed”; “session” vs “launch.”
- PAT/SSO/ETag are not expanded on first use.
- “Scope is configured by guesswork” and “fights it” are subjective.
- “live-region announcement” is web vocabulary; say accessibility announcement.
- `ReviewStatus`/`CheckSuiteStatus` have no GitHub cases; say delete both enums.
- `complete` repeats the 2xx guarantee already enforced by the throw.
- The 400 cap copy is off by one: `truncated` is `matchedCount > 400`.
- Non-draft pull requests have no marker distinct from issues.
- Open Question 1 restates the settled non-goal.
- Account-specific 52/89 numbers appear in the alternatives.

## Open Questions

1. Does Open Work fetch at launch or only after the first GitHub open?
2. Does a hide survive Clear PAT?
3. For a user above 400 matches, is “last refresh” the last complete run or the last successful one?
4. What is the dispatch payload and the no-agent/no-terminal behavior?
