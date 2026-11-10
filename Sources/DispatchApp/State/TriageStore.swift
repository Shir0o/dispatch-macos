import Foundation
import Observation

/// Disk persistence format for offline caching.
///
/// The retired GitHub arrays remain in the format so snapshots written by older
/// builds still decode. Only Gmail items are read or written.
public struct SnapshotData: Codable, Sendable {
    public let gmailItems: [TriageItem]
    public let gitHubItems: [TriageItem]
    public let savedAt: Date
    public let dismissedGitHubKeys: [String]?

    public init(
        gmailItems: [TriageItem],
        gitHubItems: [TriageItem],
        savedAt: Date = Date(),
        dismissedGitHubKeys: [String]? = nil
    ) {
        self.gmailItems = gmailItems
        self.gitHubItems = gitHubItems
        self.savedAt = savedAt
        self.dismissedGitHubKeys = dismissedGitHubKeys
    }

    private enum CodingKeys: String, CodingKey {
        case gmailItems
        case gitHubItems
        case savedAt
        case dismissedGitHubKeys
    }

    /// Tolerant decoder for snapshots written by older builds.
    ///
    /// Gmail items and `savedAt` are required; a snapshot that cannot supply
    /// them is corrupt. The retired GitHub payload is optional so an old or
    /// partial file still yields the Gmail state.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.gmailItems = try container.decode([TriageItem].self, forKey: .gmailItems)
        self.savedAt = try container.decode(Date.self, forKey: .savedAt)
        self.gitHubItems = (try? container.decode([TriageItem].self, forKey: .gitHubItems)) ?? []
        self.dismissedGitHubKeys = try? container.decodeIfPresent([String].self, forKey: .dismissedGitHubKeys)
    }

    /// Reads and decodes a snapshot from `url`.
    public static func load(from url: URL) throws -> SnapshotData {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SnapshotData.self, from: data)
    }
}

/// Central in-memory state store for the triage interface.
///
/// After the Open Work split this store owns Gmail only. `TriageSource.gitHub`
/// remains so the views can route on `activeWorkspace`, but every GitHub read
/// returns an empty fallback.
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

    public var selectedItemId: String? = nil
    public var activeWorkspace: TriageSource = .gmail
    public var toastMessage: String? = nil
    public var isToastVisible: Bool = false

    // MARK: - Injected Services

    public var gmailService: GmailService?
    public var githubService: GitHubService?
    public var authService: AuthService?

    // MARK: - Private State

    private var toastDismissTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// Items visible under the current workspace. GitHub work lives in
    /// `OpenWorkStore`; this store has no GitHub items.
    public var activeItems: [TriageItem] {
        switch activeWorkspace {
        case .gmail:
            return gmailItems
        case .gitHub:
            return []
        }
    }

    /// The currently selected item object. Selection is Gmail-only.
    public var selectedItem: TriageItem? {
        guard let selectedItemId else { return nil }
        return gmailItems.first { $0.id == selectedItemId }
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
            return 0
        }
    }

    // MARK: - Ingestion

    public func setItems(_ items: [TriageItem], for source: TriageSource) {
        switch source {
        case .gmail:
            self.gmailItems = Array(items.prefix(500))
        case .gitHub:
            // Open Work owns GitHub state; this store accepts Gmail only.
            return
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
        Self.defaultSnapshotURL
    }

    /// The on-disk snapshot location shared by the store and the legacy migration.
    public nonisolated static var defaultSnapshotURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = appSupport.appendingPathComponent("Dispatch", isDirectory: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    public func loadSnapshot() {
        let url = snapshotURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let snapshot = try SnapshotData.load(from: url)
            self.gmailItems = Array(snapshot.gmailItems.prefix(500))

            if selectedItemId == nil {
                selectedItemId = gmailItems.first?.id
            }
        } catch {
            // Quarantine the unreadable file once so the next save can proceed.
            quarantineCorruptSnapshot(at: url, error: error)
            self.gmailItems = []
            self.selectedItemId = nil
        }
    }

    /// Moves an unreadable snapshot aside as `snapshot.corrupt-<ISO8601>.json`.
    ///
    /// A rename failure is logged and leaves the file in place; either way the
    /// store starts with empty Gmail state and does not suppress later saves.
    private func quarantineCorruptSnapshot(at url: URL, error: Error) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
        let quarantineURL = url
            .deletingLastPathComponent()
            .appendingPathComponent("snapshot.corrupt-\(stamp).json")

        do {
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            print("[Dispatch] Snapshot decode failed; moved to \(quarantineURL.lastPathComponent): \(error)")
        } catch {
            print("[Dispatch] Failed to load snapshot: \(error)")
        }
    }

    public func saveSnapshotSync() {
        let snapshot = SnapshotData(
            gmailItems: Array(gmailItems.prefix(500)),
            gitHubItems: [],
            savedAt: Date(),
            dismissedGitHubKeys: nil
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
        guard item.source == .gmail else { return }

        let originalIndex = gmailItems.firstIndex(where: { $0.id == item.id })
        if let idx = originalIndex {
            gmailItems.remove(at: idx)
        }

        // Adjust selection
        if selectedItemId == item.id {
            selectedItemId = activeItems.first?.id
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let gmailService = self.gmailService else {
                    throw NSError(domain: "Dispatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gmail service not configured"])
                }
                try await gmailService.archiveThread(threadId: item.id)
            } catch {
                // Rollback on network failure
                let insertAt = min(originalIndex ?? 0, self.gmailItems.count)
                self.gmailItems.insert(item, at: insertAt)
                self.showToast("Failed to archive: \(error.localizedDescription)")
            }
        }
    }

    public func trash(item: TriageItem) {
        guard item.source == .gmail else { return }

        let originalIndex = gmailItems.firstIndex(where: { $0.id == item.id })
        if let idx = originalIndex {
            gmailItems.remove(at: idx)
        }

        if selectedItemId == item.id {
            selectedItemId = activeItems.first?.id
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let gmailService = self.gmailService else {
                    throw NSError(domain: "Dispatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gmail service not configured"])
                }
                try await gmailService.trashThread(threadId: item.id)
            } catch {
                // Rollback on failure
                let insertAt = min(originalIndex ?? 0, self.gmailItems.count)
                self.gmailItems.insert(item, at: insertAt)
                self.showToast("Failed to move to trash: \(error.localizedDescription)")
            }
        }
    }

    public func star(item: TriageItem) {
        guard item.source == .gmail else { return }

        let newStarred = !item.isStarred
        mutateItem(id: item.id) { $0.isStarred = newStarred }

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
        guard item.source == .gmail else { return }

        let newUnread = !item.isUnread
        mutateItem(id: item.id) { $0.isUnread = newUnread }
    }

    private func mutateItem(id: String, mutator: (inout TriageItem) -> Void) {
        if let idx = gmailItems.firstIndex(where: { $0.id == id }) {
            mutator(&gmailItems[idx])
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
