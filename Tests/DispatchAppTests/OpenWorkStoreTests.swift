import Foundation
import Testing
@testable import DispatchApp

// MARK: - Test Doubles

/// Thread-safe controllable clock for the injected `now` closure.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        self.current = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// A one-shot gate that keeps a fetch suspended until the test opens it.
private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Queued fetch results with a call count and an optional gate.
private actor FakeOpenWorkFetch {
    private var results: [Result<OpenWorkFetchResult, OpenWorkFetchError>]
    private var gate: AsyncGate?
    private(set) var callCount = 0

    init(_ results: [Result<OpenWorkFetchResult, OpenWorkFetchError>]) {
        self.results = results
    }

    func setGate(_ gate: AsyncGate?) {
        self.gate = gate
    }

    func fetch() async throws -> OpenWorkFetchResult {
        callCount += 1
        if let gate {
            await gate.wait()
        }
        guard !results.isEmpty else { throw OpenWorkFetchError.transport }
        return try results.removeFirst().get()
    }
}

// MARK: - Tests

@Suite("OpenWorkStore Tests")
@MainActor
struct OpenWorkStoreTests {

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "OpenWorkStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeItem(
        repository: String,
        number: Int,
        updatedAt: TimeInterval,
        kind: OpenWorkItemKind = .issue
    ) -> OpenWorkItem {
        OpenWorkItem(
            key: "\(repository.lowercased())#\(number)",
            repository: repository,
            number: number,
            kind: kind,
            title: "\(repository) #\(number)",
            authorLogin: "octocat",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            webURL: URL(string: "https://github.com/\(repository)/issues/\(number)")!
        )
    }

    private func makeResult(
        _ items: [OpenWorkItem],
        matchedCount: Int? = nil,
        fetchedCount: Int? = nil,
        truncated: Bool = false,
        complete: Bool = true
    ) -> OpenWorkFetchResult {
        OpenWorkFetchResult(
            items: items,
            matchedCount: matchedCount ?? items.count,
            fetchedCount: fetchedCount ?? items.count,
            truncated: truncated,
            complete: complete
        )
    }

    private func makeStore(
        fetch: FakeOpenWorkFetch,
        defaults: UserDefaults,
        clock: TestClock,
        isConfigured: Bool = true
    ) -> OpenWorkStore {
        OpenWorkStore(
            fetchAction: { try await fetch.fetch() },
            isConfigured: isConfigured,
            defaults: defaults,
            now: { clock.now }
        )
    }

    private func waitForCalls(_ fetch: FakeOpenWorkFetch, toReach expected: Int) async throws {
        for _ in 0..<400 {
            if await fetch.callCount >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(expected) fetch call(s)")
    }

    // MARK: - Success

    @Test("A successful refresh replaces items and updates the summary")
    func testSuccessUpdatesSummaryAndCounts() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let second = makeItem(
            repository: "Owner/Other",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let result = makeResult([first, second], matchedCount: 2)
        let fetch = FakeOpenWorkFetch([.success(result)])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()

        let calls = await fetch.callCount
        #expect(calls == 1)
        #expect(store.allItems == [first, second])
        #expect(store.visibleCount == 2)
        #expect(store.hiddenCount == 0)
        #expect(store.status.phase == .ready)
        #expect(store.status.error == nil)
        #expect(store.status.lastSuccess == baseDate)
        #expect(store.status.matchedCount == 2)
        #expect(store.status.fetchedCount == 2)
        #expect(store.status.truncated == false)
        #expect(store.status.updatedCount == 0)
        #expect(store.selectedKey == first.key)

        let data = try #require(defaults.data(forKey: "dispatch.openWorkLastRun"))
        let summary = try JSONDecoder().decode(OpenWorkLastRunSummary.self, from: data)
        #expect(summary.lastSuccess == baseDate)
        #expect(summary.matchedCount == 2)
        #expect(summary.fetchedCount == 2)
        #expect(summary.truncated == false)
    }

    @Test("A truncated success updates the summary but keeps hidden keys")
    func testTruncatedSuccessKeepsHiddenKeys() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 300
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([first, second], complete: true)),
            .success(makeResult([second], matchedCount: 601, fetchedCount: 400, truncated: true, complete: false))
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        store.hide(key: first.key)
        #expect(store.hiddenKeys.contains(first.key))

        await store.refresh()

        let calls = await fetch.callCount
        #expect(calls == 2)
        #expect(store.status.phase == .ready)
        #expect(store.status.truncated == true)
        #expect(store.status.matchedCount == 601)
        #expect(store.status.fetchedCount == 400)
        #expect(store.hiddenKeys.contains(first.key))
        #expect(store.visibleCount == 1)

        let data = try #require(defaults.data(forKey: "dispatch.openWorkLastRun"))
        let summary = try JSONDecoder().decode(OpenWorkLastRunSummary.self, from: data)
        #expect(summary.truncated == true)
        #expect(summary.matchedCount == 601)
        #expect(summary.fetchedCount == 400)
    }

    @Test("A complete success prunes hidden keys absent from the result")
    func testCompleteSuccessPrunesHiddenKeys() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([first, second], complete: true)),
            .success(makeResult([second], complete: true))
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        store.hide(key: first.key)
        #expect(store.hiddenKeys == Set([first.key]))

        await store.refresh()

        #expect(store.hiddenKeys.isEmpty)
        #expect(store.visibleCount == 1)
        #expect(store.hiddenCount == 0)
        #expect(defaults.stringArray(forKey: "dispatch.openWorkHiddenKeys") == [])
    }

    @Test("A failed refresh keeps the items and the previous summary")
    func testFailureKeepsItemsAndSummary() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let item = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([item], matchedCount: 7, fetchedCount: 1)),
            .failure(.unauthorized)
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        clock.advance(by: 901)

        await store.refreshIfDue()

        let calls = await fetch.callCount
        #expect(calls == 2)
        #expect(store.allItems == [item])
        #expect(store.status.phase == .ready)
        #expect(store.status.error == .unauthorized)
        #expect(store.status.lastSuccess == baseDate)
        #expect(store.status.matchedCount == 7)
        #expect(store.status.fetchedCount == 1)
        #expect(store.status.updatedCount == 0)
        #expect(store.visibleCount == 1)
    }

    @Test("An unknown thrown error maps to a transport failure")
    func testUnknownErrorMapsToTransport() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        struct Boom: Error {}
        let clock = TestClock(baseDate)
        let store = OpenWorkStore(
            fetchAction: { throw Boom() },
            isConfigured: true,
            defaults: defaults,
            now: { clock.now }
        )

        await store.refresh()

        #expect(store.status.error == .transport)
        #expect(store.status.phase == .idle)
        #expect(store.allItems.isEmpty)
    }

    // MARK: - Refresh Clock

    @Test("No fetch happens before the workspace is opened, then the first open fetches")
    func testNoFetchBeforeOpenThenFirstFetch() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let item = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([.success(makeResult([item]))])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.refreshIfDue()
        #expect(await fetch.callCount == 0)
        #expect(store.hasOpenedOpenWork == false)
        #expect(store.hasFetchedThisLaunch == false)

        await store.noteWorkspaceOpened()

        #expect(await fetch.callCount == 1)
        #expect(store.hasOpenedOpenWork == true)
        #expect(store.hasFetchedThisLaunch == true)
        #expect(store.visibleCount == 1)
    }

    @Test("Refreshes are throttled to one per 15 minutes, including after a failure")
    func testRefreshThrottle() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let item = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([item])),
            .success(makeResult([item])),
            .failure(.transport)
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        #expect(await fetch.callCount == 1)

        clock.advance(by: 899)
        await store.refreshIfDue()
        #expect(await fetch.callCount == 1)

        clock.advance(by: 2)
        await store.refreshIfDue()
        #expect(await fetch.callCount == 2)

        // The failed attempt started its own 15-minute window.
        clock.advance(by: 899)
        await store.refreshIfDue()
        #expect(await fetch.callCount == 2)

        clock.advance(by: 1)
        await store.refreshIfDue()
        #expect(await fetch.callCount == 3)
        #expect(store.status.error == .transport)
    }

    // MARK: - Single Flight

    @Test("Two concurrent refreshes share one in-flight fetch")
    func testSingleFlightRefresh() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let item = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([.success(makeResult([item]))])
        let gate = AsyncGate()
        await fetch.setGate(gate)
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        let first = Task { await store.refresh() }
        try await waitForCalls(fetch, toReach: 1)

        let second = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await fetch.callCount == 1)
        #expect(store.status.phase == .running)

        await gate.open()
        await first.value
        await second.value

        #expect(await fetch.callCount == 1)
        #expect(store.status.phase == .ready)
        #expect(store.visibleCount == 1)
    }

    // MARK: - Selection

    @Test("Selection falls back to the previous index and becomes nil when nothing is visible")
    func testSelectionFallbackAndEmptyList() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 300
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let third = makeItem(
            repository: "Owner/Repo",
            number: 3,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([first, second, third])),
            .success(makeResult([first, third])),
            .success(makeResult([]))
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        #expect(store.selectedKey == first.key)

        store.selectNext()
        #expect(store.selectedKey == second.key)

        await store.refresh()
        #expect(store.visibleCount == 2)
        // Previous index 1 in [first, third] lands on third.
        #expect(store.selectedKey == third.key)

        await store.refresh()
        #expect(store.visibleCount == 0)
        #expect(store.groups.isEmpty)
        #expect(store.selectedKey == nil)
        #expect(store.selectedItem == nil)
    }

    @Test("Hiding the selected item selects the next visible item")
    func testHideMovesSelectionToNextItem() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 300
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let third = makeItem(
            repository: "Owner/Repo",
            number: 3,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([.success(makeResult([first, second, third]))])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        store.selectNext()
        store.hide(key: second.key)

        #expect(store.visibleCount == 2)
        #expect(store.selectedKey == third.key)
        #expect(store.selectedItem == third)
    }

    // MARK: - Grouping

    @Test("Groups sort by newest item descending, then repository name, with items newest first")
    func testNewestFirstGrouping() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let repoAOld = makeItem(
            repository: "Owner/A",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let repoANew = makeItem(
            repository: "Owner/A",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 400
        )
        let repoB = makeItem(
            repository: "Owner/B",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 300
        )
        let repoCEqual = makeItem(
            repository: "Owner/C",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 400
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([repoAOld, repoB, repoANew, repoCEqual]))
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()

        #expect(store.groups.map(\.repository) == ["Owner/A", "Owner/C", "Owner/B"])
        #expect(store.groups[0].items.map(\.key) == [repoANew.key, repoAOld.key])
        #expect(store.groups[0].visibleCount == 2)
        #expect(store.groups[1].items.map(\.key) == [repoCEqual.key])
        #expect(store.groups[2].items.map(\.key) == [repoB.key])
    }

    // MARK: - Hide, Undo, Persistence

    @Test("Hide, unhide and the undo banner behave as one cycle")
    func testHideUnhideAndUndoBanner() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 300
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let fetch = FakeOpenWorkFetch([.success(makeResult([first, second]))])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        store.selectNext()
        #expect(store.selectedKey == second.key)

        store.hide(key: second.key)

        #expect(store.hiddenKeys == Set([second.key]))
        #expect(store.lastHiddenKey == second.key)
        #expect(store.undoDeadline == baseDate.addingTimeInterval(6))
        #expect(store.canUndo == true)
        #expect(store.visibleCount == 1)
        #expect(store.selectedKey == first.key)

        store.unhide(key: second.key)

        #expect(store.hiddenKeys.isEmpty)
        #expect(store.visibleCount == 2)
        // The banner and last key survive an undo until dismissed or expired.
        #expect(store.lastHiddenKey == second.key)
        #expect(store.canUndo == true)

        store.dismissUndoBanner()

        #expect(store.lastHiddenKey == nil)
        #expect(store.undoDeadline == nil)
        #expect(store.canUndo == false)
    }

    @Test("Hide, refresh and undo still restores the item")
    func testHideRefreshThenUndo() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([first, second], complete: true)),
            .success(makeResult([first, second], complete: true))
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        store.hide(key: first.key)
        #expect(store.visibleCount == 1)

        await store.refresh()

        // A complete run keeps a hidden key that is still in the result.
        #expect(store.hiddenKeys == Set([first.key]))
        #expect(store.visibleCount == 1)

        store.unhide(key: first.key)

        #expect(store.hiddenKeys.isEmpty)
        #expect(store.visibleCount == 2)
        #expect(store.visibleItems.contains(first))
    }

    @Test("Hidden keys hydrate in a fresh store from UserDefaults")
    func testHiddenKeyPersistenceAcrossStores() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )

        let firstFetch = FakeOpenWorkFetch([.success(makeResult([first, second]))])
        let firstStore = makeStore(fetch: firstFetch, defaults: defaults, clock: clock)
        await firstStore.noteWorkspaceOpened()
        firstStore.hide(key: first.key)

        #expect(defaults.stringArray(forKey: "dispatch.openWorkHiddenKeys") == [first.key])

        let secondFetch = FakeOpenWorkFetch([.success(makeResult([first, second]))])
        let secondStore = makeStore(fetch: secondFetch, defaults: defaults, clock: clock)

        #expect(secondStore.hiddenKeys == Set([first.key]))
        // The last-run summary hydrates for display on cold start.
        #expect(secondStore.status.lastSuccess == baseDate)
        #expect(secondStore.status.matchedCount == 2)
        #expect(secondStore.allItems.isEmpty)

        await secondStore.noteWorkspaceOpened()

        #expect(secondStore.visibleCount == 1)
        #expect(secondStore.hiddenCount == 1)
        #expect(secondStore.hiddenKeys == Set([first.key]))
    }

    @Test("Hidden count only counts keys present in the current items")
    func testAllHiddenAndHiddenCount() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let first = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 200
        )
        let second = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([.success(makeResult([first, second]))])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        store.hide(key: first.key)
        store.hide(key: second.key)

        #expect(store.visibleCount == 0)
        #expect(store.hiddenCount == 2)
        #expect(store.groups.isEmpty)
        #expect(store.selectedKey == nil)

        // A persisted key that is not in the current result is not counted.
        store.hide(key: "owner/ghost#99")
        #expect(store.hiddenKeys.count == 3)
        #expect(store.hiddenCount == 2)
    }

    // MARK: - Clear

    @Test("clear() keeps hides, disconnects, and discards an in-flight result")
    func testClearKeepsHidesAndDiscardsInFlightResult() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let item = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 + 100
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([item])),
            .success(makeResult([item]))
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        #expect(store.status.lastSuccess == baseDate)
        store.hide(key: item.key)
        #expect(store.visibleCount == 0)

        let gate = AsyncGate()
        await fetch.setGate(gate)
        let generationBefore = store.refreshGeneration
        let refresh = Task { await store.refresh() }
        try await waitForCalls(fetch, toReach: 2)
        #expect(store.status.phase == .running)

        store.clear()

        #expect(store.refreshGeneration == generationBefore + 1)
        #expect(store.isConfigured == false)
        #expect(store.allItems.isEmpty)
        #expect(store.status.phase == .idle)
        #expect(store.status.lastSuccess == nil)
        #expect(store.hiddenKeys == Set([item.key]))
        #expect(store.selectedKey == nil)
        #expect(store.lastHiddenKey == nil)
        #expect(store.undoDeadline == nil)
        #expect(defaults.data(forKey: "dispatch.openWorkLastRun") == nil)
        #expect(defaults.stringArray(forKey: "dispatch.openWorkHiddenKeys") == [item.key])

        await gate.open()
        await refresh.value

        #expect(store.allItems.isEmpty)
        #expect(store.status.phase == .idle)
        #expect(store.status.lastSuccess == nil)
        #expect(store.visibleCount == 0)
    }

    // MARK: - Updated Count

    @Test("updatedCount is zero on the first fetch and counts newer items afterwards")
    func testUpdatedCount() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = TestClock(baseDate)
        let old = makeItem(
            repository: "Owner/Repo",
            number: 1,
            updatedAt: baseDate.timeIntervalSince1970 - 1_000
        )
        let newer = makeItem(
            repository: "Owner/Repo",
            number: 2,
            updatedAt: baseDate.timeIntervalSince1970 + 60
        )
        let fetch = FakeOpenWorkFetch([
            .success(makeResult([old])),
            .success(makeResult([old, newer])),
            .success(makeResult([old, newer]))
        ])
        let store = makeStore(fetch: fetch, defaults: defaults, clock: clock)

        await store.noteWorkspaceOpened()
        #expect(store.status.updatedCount == 0)

        clock.advance(by: 900)
        await store.refresh()
        #expect(store.status.updatedCount == 1)

        clock.advance(by: 900)
        await store.refresh()
        #expect(store.status.updatedCount == 0)
    }
}
