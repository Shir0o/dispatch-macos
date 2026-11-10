import Foundation
import Network
import AppKit

// MARK: - SyncCoordinator

public actor SyncCoordinator {
    private let gmailService: GmailService

    /// Called after every sync cycle. The Open Work store owns its own 15-minute
    /// clock, so the coordinator only supplies the trigger.
    private let refreshOpenWork: @MainActor @Sendable () async -> Void

    private var isRunning: Bool = false
    private var isSleeping: Bool = false
    private var isNetworkAvailable: Bool = true

    private var pollingTask: Task<Void, Never>?
    private var sleepObserverTask: Task<Void, Never>?
    private var wakeObserverTask: Task<Void, Never>?

    public private(set) var lastGmailHistoryId: String?

    // Update callback closure
    public var onItemsUpdated: (@Sendable ([TriageItem], TriageSource) -> Void)?

    // Stream continuations for consumers subscribing via AsyncStream
    private var streamContinuations: [UUID: AsyncStream<([TriageItem], TriageSource)>.Continuation] = [:]
    private var itemStreamContinuations: [UUID: AsyncStream<[TriageItem]>.Continuation] = [:]

    private let pathMonitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.shir0o.dispatch.networkmonitor")

    public init(
        gmailService: GmailService,
        refreshOpenWork: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.gmailService = gmailService
        self.refreshOpenWork = refreshOpenWork
        self.pathMonitor = NWPathMonitor()
    }

    deinit {
        pathMonitor.cancel()
        pollingTask?.cancel()
        sleepObserverTask?.cancel()
        wakeObserverTask?.cancel()
    }

    // MARK: - Lifecycle Controls

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        isSleeping = false

        startNetworkMonitoring()
        startNotificationObservers()
        startPollingLoop()

        // Bootstrap Gmail, then let Open Work decide whether a refresh is due.
        await performSyncCycle()
        await refreshOpenWork()
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        pollingTask?.cancel()
        pollingTask = nil

        sleepObserverTask?.cancel()
        sleepObserverTask = nil

        wakeObserverTask?.cancel()
        wakeObserverTask = nil

        stopNetworkMonitoring()

        for continuation in streamContinuations.values {
            continuation.finish()
        }
        streamContinuations.removeAll()

        for continuation in itemStreamContinuations.values {
            continuation.finish()
        }
        itemStreamContinuations.removeAll()
    }

    public func syncNow() async {
        guard isRunning && !isSleeping && isNetworkAvailable else { return }
        await performSyncCycle()
    }

    public func setOnItemsUpdated(_ callback: (@Sendable ([TriageItem], TriageSource) -> Void)?) {
        self.onItemsUpdated = callback
    }

    // MARK: - AsyncStream Publishers

    public func makeItemsStream() -> AsyncStream<[TriageItem]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeItemContinuation(id: id)
                }
            }
            self.itemStreamContinuations[id] = continuation
        }
    }

    public func makeSourceStream() -> AsyncStream<([TriageItem], TriageSource)> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeSourceContinuation(id: id)
                }
            }
            self.streamContinuations[id] = continuation
        }
    }

    private func removeItemContinuation(id: UUID) {
        itemStreamContinuations.removeValue(forKey: id)
    }

    private func removeSourceContinuation(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    // MARK: - Polling Loop (Fixed 45s, Zero Jitter)

    private func startPollingLoop() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Continuous 45-second timer loop with zero jitter
                    try await Task.sleep(for: .seconds(45))
                } catch {
                    break // Task cancelled
                }
                guard let self = self else { break }
                await self.performSyncCycle()
                await self.refreshOpenWork()
            }
        }
    }

    // MARK: - Sync Execution

    public func performSyncCycle() async {
        guard isRunning && !isSleeping && isNetworkAvailable else { return }
        await syncGmail()
    }

    private func syncGmail() async {
        if let historyId = lastGmailHistoryId {
            do {
                let history = try await gmailService.fetchHistory(startHistoryId: historyId)
                self.lastGmailHistoryId = history.newHistoryId

                // If threads were added or removed from inbox, reconcile
                if !history.addedThreadIds.isEmpty || !history.removedThreadIds.isEmpty {
                    let reconciliation = try await gmailService.fetchInboxThreads(pageToken: nil)
                    self.lastGmailHistoryId = reconciliation.historyId ?? history.newHistoryId
                    emitUpdate(items: reconciliation.items, source: .gmail)
                }
            } catch let error as GmailError where error == .invalidHistoryId {
                // HTTP 404 INVALID_HISTORY_ID: Clear stale ID and perform full inbox reconciliation
                self.lastGmailHistoryId = nil
                do {
                    let reconciliation = try await gmailService.fetchInboxThreads(pageToken: nil)
                    self.lastGmailHistoryId = reconciliation.historyId
                    emitUpdate(items: reconciliation.items, source: .gmail)
                } catch {
                    // Backoff silently until next sync cycle
                }
            } catch {
                // Network or auth error; will retry on next polling loop
            }
        } else {
            // Cold bootstrap
            do {
                let initial = try await gmailService.fetchInboxThreads(pageToken: nil)
                self.lastGmailHistoryId = initial.historyId
                emitUpdate(items: initial.items, source: .gmail)
            } catch {
                // Backoff silently until next sync cycle
            }
        }
    }

    private func emitUpdate(items: [TriageItem], source: TriageSource) {
        onItemsUpdated?(items, source)

        for continuation in streamContinuations.values {
            continuation.yield((items, source))
        }

        for continuation in itemStreamContinuations.values {
            continuation.yield(items)
        }
    }

    // MARK: - Network Reachability (NWPathMonitor)

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            Task {
                await self.updateNetworkStatus(isAvailable: path.status == .satisfied)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func stopNetworkMonitoring() {
        pathMonitor.cancel()
    }

    public func updateNetworkStatus(isAvailable: Bool) {
        let wasUnavailable = !self.isNetworkAvailable && isAvailable
        self.isNetworkAvailable = isAvailable

        // Reconnection triggers immediate sync cycle
        if wasUnavailable && isRunning && !isSleeping {
            Task {
                await self.performSyncCycle()
            }
        }
    }

    // MARK: - System Sleep / Wake Handlers

    private func startNotificationObservers() {
        sleepObserverTask?.cancel()
        sleepObserverTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification) {
                guard !Task.isCancelled else { break }
                await self?.handleSystemWillSleep()
            }
        }

        wakeObserverTask?.cancel()
        wakeObserverTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                guard !Task.isCancelled else { break }
                await self?.handleSystemDidWake()
            }
        }
    }

    public func handleSystemWillSleep() {
        isSleeping = true
        // Zero CPU wakeups during system sleep
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func handleSystemDidWake() {
        isSleeping = false
        if isRunning {
            startPollingLoop()
            Task {
                await self.performSyncCycle()
                await self.refreshOpenWork()
            }
        }
    }

    // MARK: - State Inspection (for Tests & Diagnostics)

    public func getStatus() -> (
        isRunning: Bool,
        isSleeping: Bool,
        isNetworkAvailable: Bool,
        lastGmailHistoryId: String?
    ) {
        return (isRunning, isSleeping, isNetworkAvailable, lastGmailHistoryId)
    }
}
