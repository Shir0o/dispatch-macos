import Foundation
import Observation

/// Smart filter options for GitHub notifications.
public enum GitHubFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case ciAlerts = "CI Alerts"
    case mentions = "Mentions"
    case reviewRequests = "Review Requests"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .all:
            return "tray.full"
        case .ciAlerts:
            return "exclamationmark.triangle"
        case .mentions:
            return "at"
        case .reviewRequests:
            return "arrow.triangle.pull"
        }
    }
}

/// Disk persistence format for offline caching.
public struct SnapshotData: Codable, Sendable {
    public let gmailItems: [TriageItem]
    public let gitHubItems: [TriageItem]
    public let savedAt: Date

    public init(gmailItems: [TriageItem], gitHubItems: [TriageItem], savedAt: Date = Date()) {
        self.gmailItems = gmailItems
        self.gitHubItems = gitHubItems
        self.savedAt = savedAt
    }
}

/// Central in-memory state store for the triage interface.
@Observable
@MainActor
public final class TriageStore {
    // MARK: - Published State

    public var gmailItems: [TriageItem] = [] {
        didSet {
            if gmailItems.count > 500 {
                gmailItems = Array(gmailItems.prefix(500))
            }
        }
    }

    public var gitHubItems: [TriageItem] = [] {
        didSet {
            if gitHubItems.count > 500 {
                gitHubItems = Array(gitHubItems.prefix(500))
            }
        }
    }

    public var selectedItemId: String? = nil
    public var activeWorkspace: TriageSource = .gmail
    public var gitHubFilter: GitHubFilter = .all
    public var toastMessage: String? = nil
    public var isToastVisible: Bool = false
    public var isLoading: Bool = false

    // MARK: - Injected Services

    public var gmailService: GmailService?
    public var githubService: GitHubService?
    public var authService: AuthService?

    // MARK: - Private State

    private var toastDismissTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// GitHub items filtered by the active smart filter.
    public var filteredGitHubItems: [TriageItem] {
        switch gitHubFilter {
        case .all:
            return gitHubItems
        case .ciAlerts:
            return gitHubItems.filter { item in
                if item.tags.contains("ci_activity") { return true }
                if case .gitHubPullRequest(_, _, _, _, let ciStatus) = item.kind {
                    return ciStatus == .completedFailure || ciStatus == .queued || ciStatus == .inProgress
                }
                return false
            }
        case .mentions:
            return gitHubItems.filter { item in
                item.tags.contains("mention") || item.tags.contains("team_mention")
            }
        case .reviewRequests:
            return gitHubItems.filter { item in
                if item.tags.contains("review_requested") || item.tags.contains("review_request") { return true }
                if case .gitHubPullRequest(_, _, _, let reviewStatus, _) = item.kind {
                    return reviewStatus == .pending || reviewStatus == .changesRequested
                }
                return false
            }
        }
    }

    /// Items visible under the current workspace and filter settings.
    public var activeItems: [TriageItem] {
        switch activeWorkspace {
        case .gmail:
            return gmailItems
        case .gitHub:
            return filteredGitHubItems
        }
    }

    /// The currently selected item object.
    public var selectedItem: TriageItem? {
        guard let selectedItemId else { return nil }
        return activeItems.first { $0.id == selectedItemId }
            ?? gmailItems.first { $0.id == selectedItemId }
            ?? gitHubItems.first { $0.id == selectedItemId }
    }

    // MARK: - Initialization

    public init(
        gmailService: GmailService? = nil,
        githubService: GitHubService? = nil,
        authService: AuthService? = nil
    ) {
        self.gmailService = gmailService
        self.githubService = githubService
        self.authService = authService
    }

    // MARK: - Unread Counts

    public func unreadCount(for source: TriageSource) -> Int {
        switch source {
        case .gmail:
            return gmailItems.filter { $0.isUnread }.count
        case .gitHub:
            return gitHubItems.filter { $0.isUnread }.count
        }
    }

    // MARK: - Ingestion

    public func setItems(_ items: [TriageItem], for source: TriageSource) {
        let bounded = Array(items.prefix(500))
        switch source {
        case .gmail:
            self.gmailItems = bounded
        case .gitHub:
            self.gitHubItems = bounded
        }

        // Maintain selection validity
        if selectedItemId == nil || !activeItems.contains(where: { $0.id == selectedItemId }) {
            selectedItemId = activeItems.first?.id
        }
    }

    // MARK: - Keyboard Selection Navigation

    public func selectNext() {
        let items = activeItems
        guard !items.isEmpty else { return }
        guard let currentId = selectedItemId,
              let currentIndex = items.firstIndex(where: { $0.id == currentId }) else {
            selectedItemId = items.first?.id
            return
        }
        let nextIndex = min(currentIndex + 1, items.count - 1)
        selectedItemId = items[nextIndex].id
    }

    public func selectPrevious() {
        let items = activeItems
        guard !items.isEmpty else { return }
        guard let currentId = selectedItemId,
              let currentIndex = items.firstIndex(where: { $0.id == currentId }) else {
            selectedItemId = items.first?.id
            return
        }
        let prevIndex = max(currentIndex - 1, 0)
        selectedItemId = items[prevIndex].id
    }

    // MARK: - Snapshot Persistence

    private var snapshotURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = appSupport.appendingPathComponent("Dispatch", isDirectory: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    public func loadSnapshot() {
        let url = snapshotURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let snapshot = try decoder.decode(SnapshotData.self, from: data)
            self.gmailItems = Array(snapshot.gmailItems.prefix(500))
            self.gitHubItems = Array(snapshot.gitHubItems.prefix(500))

            if selectedItemId == nil {
                selectedItemId = activeItems.first?.id
            }
        } catch {
            print("[Dispatch] Failed to load snapshot: \(error)")
        }
    }

    public func saveSnapshotSync() {
        let snapshot = SnapshotData(
            gmailItems: Array(gmailItems.prefix(500)),
            gitHubItems: Array(gitHubItems.prefix(500)),
            savedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(snapshot)
            let url = snapshotURL
            let dir = url.deletingLastPathComponent()

            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            print("[Dispatch] Failed to write snapshot synchronously: \(error)")
        }
    }

    // MARK: - Optimistic Actions

    public func archive(item: TriageItem) {
        let originalIndex: Int?
        let originalSource = item.source

        if originalSource == .gmail {
            originalIndex = gmailItems.firstIndex(where: { $0.id == item.id })
            if let idx = originalIndex {
                gmailItems.remove(at: idx)
            }
        } else {
            originalIndex = gitHubItems.firstIndex(where: { $0.id == item.id })
            if let idx = originalIndex {
                gitHubItems.remove(at: idx)
            }
        }

        // Adjust selection
        if selectedItemId == item.id {
            selectedItemId = activeItems.first?.id
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                if originalSource == .gmail {
                    guard let gmailService = self.gmailService else {
                        throw NSError(domain: "Dispatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gmail service not configured"])
                    }
                    try await gmailService.archiveThread(threadId: item.id)
                } else {
                    guard let githubService = self.githubService else {
                        throw NSError(domain: "Dispatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "GitHub service not configured"])
                    }
                    try await githubService.dismissNotification(threadId: item.id)
                }
            } catch {
                // Rollback on network failure
                if originalSource == .gmail {
                    let insertAt = min(originalIndex ?? 0, self.gmailItems.count)
                    self.gmailItems.insert(item, at: insertAt)
                } else {
                    let insertAt = min(originalIndex ?? 0, self.gitHubItems.count)
                    self.gitHubItems.insert(item, at: insertAt)
                }
                self.showToast("Failed to archive: \(error.localizedDescription)")
            }
        }
    }

    public func trash(item: TriageItem) {
        let originalIndex: Int?
        let originalSource = item.source

        if originalSource == .gmail {
            originalIndex = gmailItems.firstIndex(where: { $0.id == item.id })
            if let idx = originalIndex {
                gmailItems.remove(at: idx)
            }
        } else {
            originalIndex = gitHubItems.firstIndex(where: { $0.id == item.id })
            if let idx = originalIndex {
                gitHubItems.remove(at: idx)
            }
        }

        if selectedItemId == item.id {
            selectedItemId = activeItems.first?.id
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                if originalSource == .gmail {
                    guard let gmailService = self.gmailService else {
                        throw NSError(domain: "Dispatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gmail service not configured"])
                    }
                    try await gmailService.trashThread(threadId: item.id)
                } else {
                    guard let githubService = self.githubService else {
                        throw NSError(domain: "Dispatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "GitHub service not configured"])
                    }
                    try await githubService.unsubscribeNotification(threadId: item.id)
                }
            } catch {
                // Rollback on failure
                if originalSource == .gmail {
                    let insertAt = min(originalIndex ?? 0, self.gmailItems.count)
                    self.gmailItems.insert(item, at: insertAt)
                } else {
                    let insertAt = min(originalIndex ?? 0, self.gitHubItems.count)
                    self.gitHubItems.insert(item, at: insertAt)
                }
                self.showToast("Failed to move to trash: \(error.localizedDescription)")
            }
        }
    }

    public func star(item: TriageItem) {
        let newStarred = !item.isStarred
        mutateItem(id: item.id) { $0.isStarred = newStarred }

        guard item.source == .gmail else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let gmailService = self.gmailService else { return }
                try await gmailService.starThread(threadId: item.id, starred: newStarred)
            } catch {
                // Rollback
                self.mutateItem(id: item.id) { $0.isStarred = !newStarred }
                self.showToast("Failed to star thread: \(error.localizedDescription)")
            }
        }
    }

    public func markUnread(item: TriageItem) {
        let newUnread = !item.isUnread
        mutateItem(id: item.id) { $0.isUnread = newUnread }
    }

    private func mutateItem(id: String, mutator: (inout TriageItem) -> Void) {
        if let idx = gmailItems.firstIndex(where: { $0.id == id }) {
            mutator(&gmailItems[idx])
        }
        if let idx = gitHubItems.firstIndex(where: { $0.id == id }) {
            mutator(&gitHubItems[idx])
        }
    }

    // MARK: - Toast Banner

    public func showToast(_ message: String) {
        toastMessage = message
        isToastVisible = true

        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.isToastVisible = false
        }
    }
}
