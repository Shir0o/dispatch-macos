import Foundation
import Observation

/// Main-actor state store for the GitHub Open Work view.
///
/// Owns the fetch, the refresh clock, the status the view reads, the selected
/// item, the cached repository groups, and the locally hidden keys. Imported
/// work is never counted as unread and is held in memory only; hidden keys and
/// the last-run summary survive relaunch.
@MainActor
@Observable
public final class OpenWorkStore {
    // MARK: - Constants

    /// Persisted hidden keys, lowercased `owner/repo#number` strings.
    static let hiddenKeysDefaultsKey = "dispatch.openWorkHiddenKeys"
    /// Persisted `OpenWorkLastRunSummary` JSON.
    static let lastRunDefaultsKey = "dispatch.openWorkLastRun"
    /// A refresh runs at most once per 15 minutes after the first open.
    static let refreshInterval: TimeInterval = 15 * 60
    /// How long the hide/undo banner stays actionable.
    static let undoWindow: TimeInterval = 6

    // MARK: - Stored State

    /// The source of truth, replaced on every successful refresh.
    public private(set) var allItems: [OpenWorkItem] = []

    /// Every locally hidden key. Not bounded by what the current result holds,
    /// so a hide survives a run that does not return the item.
    public private(set) var hiddenKeys: Set<String> = []

    /// The key of the most recent hide, addressable by Undo while `canUndo`.
    public private(set) var lastHiddenKey: String?

    /// When the hide/undo banner stops accepting undo.
    public private(set) var undoDeadline: Date?

    /// The refresh state the view header reads.
    public private(set) var status = OpenWorkStatus()

    /// The selected item key, preserved across refreshes when possible.
    public private(set) var selectedKey: String?

    /// Repository sections built from the visible items, cached on mutation.
    public private(set) var groups: [OpenWorkGroup] = []

    /// Number of visible items, cached on mutation.
    public private(set) var visibleCount = 0

    /// Number of hidden keys present in `allItems`, cached on mutation.
    public private(set) var hiddenCount = 0

    /// The start of the most recent attempt, successful or not.
    public private(set) var lastAttempt: Date?

    /// True once a refresh has run in this launch, independent of outcome.
    public private(set) var hasFetchedThisLaunch = false

    /// True once the GitHub workspace has been opened in this launch.
    public private(set) var hasOpenedOpenWork = false

    /// Set from the Keychain at launch and by Settings on validate or clear.
    public var isConfigured: Bool

    /// Incremented when an in-flight result must be discarded.
    public private(set) var refreshGeneration = 0

    // MARK: - Injected Dependencies

    @ObservationIgnored private let fetchAction: @Sendable () async throws -> OpenWorkFetchResult
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date

    // MARK: - Private State

    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Identity for `refreshTask`. Task is not Equatable, so this lets a
    /// finishing caller avoid clearing a newer task.
    @ObservationIgnored private var refreshTaskToken: UUID?

    // MARK: - Derived State

    /// `allItems` minus the hidden keys, preserving result order.
    public var visibleItems: [OpenWorkItem] {
        allItems.filter { !hiddenKeys.contains($0.key) }
    }

    /// The item for `selectedKey`, if it is still visible.
    public var selectedItem: OpenWorkItem? {
        guard let selectedKey else { return nil }
        return visibleItems.first { $0.key == selectedKey }
    }

    /// True while the last hide can still be undone.
    public var canUndo: Bool {
        guard let undoDeadline else { return false }
        return undoDeadline > now()
    }

    /// The visible items in flattened group order.
    private var flattenedVisibleItems: [OpenWorkItem] {
        groups.flatMap(\.items)
    }

    // MARK: - Initialization

    public init(
        fetchAction: @escaping @Sendable () async throws -> OpenWorkFetchResult,
        isConfigured: Bool,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetchAction = fetchAction
        self.isConfigured = isConfigured
        self.defaults = defaults
        self.now = now

        self.hiddenKeys = Set(
            (defaults.stringArray(forKey: Self.hiddenKeysDefaultsKey) ?? [])
                .map { $0.lowercased() }
        )

        self.status = OpenWorkStatus()
        if let data = defaults.data(forKey: Self.lastRunDefaultsKey),
           let summary = try? JSONDecoder().decode(OpenWorkLastRunSummary.self, from: data) {
            // Display-only hydration. `updatedCount` stays 0 at launch.
            self.status.lastSuccess = summary.lastSuccess
            self.status.matchedCount = summary.matchedCount
            self.status.fetchedCount = summary.fetchedCount
            self.status.truncated = summary.truncated
        }

        recompute()
    }

    // MARK: - Refresh Clock

    /// Marks the workspace as opened and refreshes when due.
    public func noteWorkspaceOpened() async {
        hasOpenedOpenWork = true
        await refreshIfDue()
    }

    /// Refreshes only when connected, opened, idle, and outside the throttle.
    public func refreshIfDue() async {
        guard isConfigured, hasOpenedOpenWork, refreshTask == nil else { return }
        if hasFetchedThisLaunch {
            let elapsed = now().timeIntervalSince(lastAttempt ?? .distantPast)
            guard elapsed >= Self.refreshInterval else { return }
        }
        await refresh()
    }

    // MARK: - Refresh

    /// Runs one fetch. Concurrent callers await the same in-flight task.
    public func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        let generation = refreshGeneration
        let token = UUID()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation)
        }
        refreshTask = task
        refreshTaskToken = token

        await task.value

        // Only the caller that still owns the current task clears it.
        if refreshTaskToken == token {
            refreshTask = nil
            refreshTaskToken = nil
        }
    }

    private func performRefresh(generation: Int) async {
        // `clear()` may have run before this task got a turn.
        guard isConfigured, generation == refreshGeneration else { return }

        let isFirstFetch = !hasFetchedThisLaunch
        lastAttempt = now()
        hasFetchedThisLaunch = true
        status.phase = .running
        status.error = nil

        do {
            let result = try await fetchAction()
            guard isConfigured, generation == refreshGeneration else { return }
            applySuccess(result, isFirstFetch: isFirstFetch)
        } catch {
            guard isConfigured, generation == refreshGeneration else { return }
            applyFailure(error)
        }
    }

    // MARK: - Applying Results

    private func applySuccess(_ result: OpenWorkFetchResult, isFirstFetch: Bool) {
        // Capture the old position before the list is replaced.
        let previousIndex = selectedKey.flatMap { key in
            groups.flatMap(\.items).firstIndex { $0.key == key }
        }
        let previousLastSuccess = status.lastSuccess

        allItems = result.items

        status.phase = .ready
        status.error = nil
        status.matchedCount = result.matchedCount
        status.fetchedCount = result.fetchedCount
        status.truncated = result.truncated

        if !isFirstFetch, let previousLastSuccess {
            status.updatedCount = result.items.filter { $0.updatedAt > previousLastSuccess }.count
        } else {
            status.updatedCount = 0
        }

        status.lastSuccess = now()

        // Only a complete run may drop hidden keys.
        if result.complete {
            hiddenKeys.formIntersection(result.items.map(\.key))
            persistHiddenKeys()
        }

        recompute()

        if let selectedKey, visibleItems.contains(where: { $0.key == selectedKey }) {
            // The selection survived the refresh.
        } else {
            let items = flattenedVisibleItems
            if items.isEmpty {
                selectedKey = nil
            } else {
                let index = min(previousIndex ?? 0, items.count - 1)
                selectedKey = items[index].key
            }
        }

        persistSummary()
    }

    private func applyFailure(_ error: Error) {
        // Keep every prior list and summary field; only the error changes.
        status.error = (error as? OpenWorkFetchError) ?? .transport
        status.phase = allItems.isEmpty ? .idle : .ready
    }

    // MARK: - Hidden Keys

    /// Hides one item, records it for undo, and starts the 6-second banner.
    public func hide(key: String) {
        let normalizedKey = key.lowercased()
        let previousIndex = selectedKey.flatMap { selected in
            groups.flatMap(\.items).firstIndex { $0.key == selected }
        }
        let wasSelected = selectedKey == normalizedKey

        hiddenKeys.insert(normalizedKey)
        lastHiddenKey = normalizedKey
        undoDeadline = now().addingTimeInterval(Self.undoWindow)
        persistHiddenKeys()
        recompute()

        if wasSelected || (selectedKey != nil && !visibleItems.contains(where: { $0.key == selectedKey })) {
            let items = flattenedVisibleItems
            if items.isEmpty {
                selectedKey = nil
            } else {
                let index = min(previousIndex ?? 0, items.count - 1)
                selectedKey = items[index].key
            }
        }

        startUndoBanner()
    }

    /// Restores one hidden item.
    public func unhide(key: String) {
        hiddenKeys.remove(key.lowercased())
        persistHiddenKeys()
        recompute()
    }

    /// Removes every persisted hidden key.
    public func clearAllHidden() {
        hiddenKeys.removeAll()
        persistHiddenKeys()
        recompute()
        dismissUndoBanner()
    }

    /// Ends the undo window and hides the banner.
    public func dismissUndoBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        lastHiddenKey = nil
        undoDeadline = nil
    }

    private func startUndoBanner() {
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.undoWindow))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismissUndoBanner()
        }
    }

    // MARK: - Selection

    public func selectNext() {
        let items = flattenedVisibleItems
        guard !items.isEmpty else { return }
        guard let currentKey = selectedKey,
              let index = items.firstIndex(where: { $0.key == currentKey }) else {
            self.selectedKey = items.first?.key
            return
        }
        self.selectedKey = items[min(index + 1, items.count - 1)].key
    }

    public func selectPrevious() {
        let items = flattenedVisibleItems
        guard !items.isEmpty else { return }
        guard let currentKey = selectedKey,
              let index = items.firstIndex(where: { $0.key == currentKey }) else {
            self.selectedKey = items.first?.key
            return
        }
        self.selectedKey = items[max(index - 1, 0)].key
    }

    // MARK: - Clear

    /// Disconnects the store. Keeps hidden keys; discards all in-memory work and
    /// any fetch that is still in flight.
    public func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskToken = nil
        refreshGeneration += 1

        allItems = []
        status = OpenWorkStatus()
        selectedKey = nil
        isConfigured = false
        defaults.removeObject(forKey: Self.lastRunDefaultsKey)

        dismissUndoBanner()
        recompute()
    }

    // MARK: - Recompute

    private func recompute() {
        let visible = visibleItems
        let grouped = Dictionary(grouping: visible, by: \.repository)

        groups = grouped.map { repository, items in
            OpenWorkGroup(
                repository: repository,
                items: items.sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt {
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    return lhs.key < rhs.key
                },
                visibleCount: items.count
            )
        }.sorted { lhs, rhs in
            let lhsNewest = lhs.items.first?.updatedAt ?? .distantPast
            let rhsNewest = rhs.items.first?.updatedAt ?? .distantPast
            if lhsNewest != rhsNewest {
                return lhsNewest > rhsNewest
            }
            return lhs.repository < rhs.repository
        }

        visibleCount = visible.count
        hiddenCount = Set(allItems.map(\.key)).intersection(hiddenKeys).count
    }

    // MARK: - Persistence

    private func persistHiddenKeys() {
        defaults.set(hiddenKeys.sorted(), forKey: Self.hiddenKeysDefaultsKey)
    }

    private func persistSummary() {
        let summary = OpenWorkLastRunSummary(
            lastSuccess: status.lastSuccess,
            matchedCount: status.matchedCount,
            fetchedCount: status.fetchedCount,
            truncated: status.truncated
        )
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: Self.lastRunDefaultsKey)
    }
}
