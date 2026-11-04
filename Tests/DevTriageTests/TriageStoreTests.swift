import Foundation
import Testing
@testable import DevTriage

@Suite("TriageStore Tests")
@MainActor
struct TriageStoreTests {

    // MARK: - Helper Functions

    private func makeTestItem(
        id: String,
        source: TriageSource,
        title: String = "Test Item",
        isUnread: Bool = true,
        tags: [String] = []
    ) -> TriageItem {
        let kind: TriageKind = source == .gmail
            ? .email(threadId: id, snippet: "Snippet for \(id)", hasHtml: false)
            : .gitHubIssue(number: 1, repo: "owner/repo", state: "open", isAssignedToMe: true)

        return TriageItem(
            id: id,
            source: source,
            title: title,
            authorName: "Author \(id)",
            authorAvatarURL: nil,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            isUnread: isUnread,
            isStarred: false,
            isArchived: false,
            tags: tags,
            kind: kind,
            webURL: URL(string: "https://example.com/\(id)")!
        )
    }

    private func getSnapshotURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = appSupport.appendingPathComponent("DevTriage", isDirectory: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - 500-Item Prefix Capping Tests

    @Test("Direct assignment to gmailItems caps at 500 elements")
    func testGmailItemsDirectAssignmentCapping() {
        let store = TriageStore()
        let items = (0..<600).map { i in
            makeTestItem(id: "gmail-\(i)", source: .gmail, title: "Email \(i)")
        }

        store.gmailItems = items

        #expect(store.gmailItems.count == 500)
        #expect(store.gmailItems.first?.id == "gmail-0")
        #expect(store.gmailItems.last?.id == "gmail-499")
    }

    @Test("Direct assignment to gitHubItems caps at 500 elements")
    func testGitHubItemsDirectAssignmentCapping() {
        let store = TriageStore()
        let items = (0..<600).map { i in
            makeTestItem(id: "github-\(i)", source: .gitHub, title: "Issue \(i)")
        }

        store.gitHubItems = items

        #expect(store.gitHubItems.count == 500)
        #expect(store.gitHubItems.first?.id == "github-0")
        #expect(store.gitHubItems.last?.id == "github-499")
    }

    @Test("setItems caps Gmail items at 500 elements and preserves item ordering")
    func testSetItemsGmailCapping() {
        let store = TriageStore()
        let items = (0..<750).map { i in
            makeTestItem(id: "gmail-bulk-\(i)", source: .gmail, title: "Thread \(i)")
        }

        store.setItems(items, for: .gmail)

        #expect(store.gmailItems.count == 500)
        #expect(store.gmailItems[0].id == "gmail-bulk-0")
        #expect(store.gmailItems[499].id == "gmail-bulk-499")
        #expect(store.selectedItemId == "gmail-bulk-0")
    }

    @Test("setItems caps GitHub items at 500 elements")
    func testSetItemsGitHubCapping() {
        let store = TriageStore()
        let items = (0..<550).map { i in
            makeTestItem(id: "github-bulk-\(i)", source: .gitHub, title: "PR \(i)")
        }

        store.setItems(items, for: .gitHub)

        #expect(store.gitHubItems.count == 500)
        #expect(store.gitHubItems[0].id == "github-bulk-0")
        #expect(store.gitHubItems[499].id == "github-bulk-499")
    }

    @Test("Items below 500 are fully preserved without capping")
    func testItemsBelow500Preserved() {
        let store = TriageStore()
        let count = 42
        let items = (0..<count).map { i in
            makeTestItem(id: "item-\(i)", source: .gmail, title: "Item \(i)")
        }

        store.gmailItems = items
        #expect(store.gmailItems.count == count)
        #expect(store.unreadCount(for: .gmail) == count)
    }

    // MARK: - Optimistic Archive Deletion & Rollback Tests

    @Test("Optimistic archive immediately removes Gmail item and rolls back on service failure")
    func testGmailArchiveOptimisticDeletionAndRollback() async throws {
        let store = TriageStore()

        let item0 = makeTestItem(id: "g0", source: .gmail, title: "First")
        let item1 = makeTestItem(id: "g1", source: .gmail, title: "Target to Archive")
        let item2 = makeTestItem(id: "g2", source: .gmail, title: "Third")
        store.gmailItems = [item0, item1, item2]

        // Configure GmailService that simulates network failure
        MockURLProtocol.reset()
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString, url.contains("modify") else { return nil }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let errorJSON = "{\"error\": {\"code\": 500, \"message\": \"Internal Server Error\"}}"
            return (resp, Data(errorJSON.utf8))
        }

        let session = makeMockSession()
        let failingService = GmailService(session: session) { "mock-token" }
        store.gmailService = failingService

        // 1. Optimistic removal: item1 should be removed synchronously
        store.archive(item: item1)
        #expect(store.gmailItems.count == 2)
        #expect(!store.gmailItems.contains(where: { $0.id == "g1" }))

        // 2. Await asynchronous Task failure and rollback
        var rolledBack = false
        for _ in 0..<50 {
            if store.gmailItems.contains(where: { $0.id == "g1" }) {
                rolledBack = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        #expect(rolledBack == true)
        #expect(store.gmailItems.count == 3)
        // Verify item was restored to its original index (index 1)
        #expect(store.gmailItems[1].id == "g1")
        #expect(store.toastMessage?.contains("Failed to archive") == true)
        #expect(store.isToastVisible == true)
    }

    @Test("Optimistic archive rolls back when GmailService is not configured")
    func testGmailArchiveRollbackWhenServiceNotConfigured() async throws {
        let store = TriageStore()
        let item = makeTestItem(id: "g-alone", source: .gmail, title: "Alone")
        store.gmailItems = [item]
        store.gmailService = nil

        store.archive(item: item)
        #expect(store.gmailItems.isEmpty)

        // Wait for rollback Task
        for _ in 0..<50 {
            if store.gmailItems.contains(where: { $0.id == "g-alone" }) {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(store.gmailItems.count == 1)
        #expect(store.gmailItems.first?.id == "g-alone")
        #expect(store.toastMessage?.contains("Gmail service not configured") == true)
    }

    @Test("Optimistic archive immediately removes GitHub item and rolls back on failure")
    func testGitHubArchiveOptimisticDeletionAndRollback() async throws {
        let store = TriageStore()

        let item0 = makeTestItem(id: "gh0", source: .gitHub, title: "First PR")
        let item1 = makeTestItem(id: "gh1", source: .gitHub, title: "Target Issue")
        let item2 = makeTestItem(id: "gh2", source: .gitHub, title: "Third PR")
        store.gitHubItems = [item0, item1, item2]

        // Mock GitHub failure
        MockURLProtocol.reset()
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString, url.contains("notifications/threads") else { return nil }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, Data("{\"message\": \"Service Unavailable\"}".utf8))
        }

        let session = makeMockSession()
        let failingGithub = GitHubService(session: session) { "mock-token" }
        store.githubService = failingGithub

        // Optimistic removal
        store.archive(item: item1)
        #expect(store.gitHubItems.count == 2)
        #expect(!store.gitHubItems.contains(where: { $0.id == "gh1" }))

        // Wait for rollback
        var rolledBack = false
        for _ in 0..<50 {
            if store.gitHubItems.contains(where: { $0.id == "gh1" }) {
                rolledBack = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(rolledBack == true)
        #expect(store.gitHubItems.count == 3)
        #expect(store.gitHubItems[1].id == "gh1")
        #expect(store.toastMessage?.contains("Failed to archive") == true)
    }

    @Test("Successful archive keeps item removed and does not trigger rollback")
    func testSuccessfulArchiveMaintainsDeletion() async throws {
        let store = TriageStore()

        let item0 = makeTestItem(id: "g0", source: .gmail, title: "Keep")
        let item1 = makeTestItem(id: "g1", source: .gmail, title: "Archive Me")
        store.gmailItems = [item0, item1]

        MockURLProtocol.reset()
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString, url.contains("modify") else { return nil }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, Data("{}".utf8))
        }

        let session = makeMockSession()
        store.gmailService = GmailService(session: session) { "mock-token" }

        store.archive(item: item1)
        #expect(store.gmailItems.count == 1)
        #expect(store.gmailItems.first?.id == "g0")

        // Wait briefly to confirm no rollback occurs
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.gmailItems.count == 1)
        #expect(!store.gmailItems.contains(where: { $0.id == "g1" }))
        #expect(store.toastMessage == nil)
    }

    // MARK: - Snapshot Persistence Tests

    @Test("Synchronous atomic snapshot serialization and cold-start deserialization")
    func testSnapshotSaveAndLoad() throws {
        let snapshotURL = getSnapshotURL()
        let backupData = try? Data(contentsOf: snapshotURL)
        defer {
            if let backupData {
                try? backupData.write(to: snapshotURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }

        let store = TriageStore()
        let gmailItem = makeTestItem(
            id: "gmail-snap-1",
            source: .gmail,
            title: "Architecture Discussion",
            isUnread: true,
            tags: ["INBOX", "IMPORTANT"]
        )
        let githubItem = TriageItem(
            id: "gh-snap-1",
            source: .gitHub,
            title: "Fix Actor Isolation in SyncEngine",
            authorName: "octocat",
            authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"),
            timestamp: Date(timeIntervalSince1970: 1700000000),
            isUnread: false,
            isStarred: true,
            isArchived: false,
            tags: ["ci_activity", "review_requested"],
            kind: .gitHubPullRequest(
                number: 42,
                repo: "org/repo",
                isDraft: false,
                reviewStatus: .changesRequested,
                ciStatus: .completedFailure
            ),
            webURL: URL(string: "https://github.com/org/repo/pull/42")!
        )

        store.gmailItems = [gmailItem]
        store.gitHubItems = [githubItem]

        // Save synchronously
        store.saveSnapshotSync()

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

        // Verify snapshot file decodes valid SnapshotData
        let fileData = try Data(contentsOf: snapshotURL)
        let decoded = try JSONDecoder().decode(SnapshotData.self, from: fileData)
        #expect(decoded.gmailItems.count == 1)
        #expect(decoded.gitHubItems.count == 1)

        // Cold-start with fresh store
        let freshStore = TriageStore()
        #expect(freshStore.gmailItems.isEmpty)
        #expect(freshStore.gitHubItems.isEmpty)

        freshStore.loadSnapshot()

        #expect(freshStore.gmailItems.count == 1)
        #expect(freshStore.gitHubItems.count == 1)

        let loadedGmail = freshStore.gmailItems.first
        #expect(loadedGmail?.id == "gmail-snap-1")
        #expect(loadedGmail?.title == "Architecture Discussion")
        #expect(loadedGmail?.tags == ["INBOX", "IMPORTANT"])
        #expect(loadedGmail?.isUnread == true)

        let loadedGitHub = freshStore.gitHubItems.first
        #expect(loadedGitHub?.id == "gh-snap-1")
        #expect(loadedGitHub?.title == "Fix Actor Isolation in SyncEngine")
        #expect(loadedGitHub?.authorName == "octocat")
        #expect(loadedGitHub?.isStarred == true)
        #expect(loadedGitHub?.isUnread == false)

        if case .gitHubPullRequest(let number, let repo, let isDraft, let reviewStatus, let ciStatus) = loadedGitHub?.kind {
            #expect(number == 42)
            #expect(repo == "org/repo")
            #expect(isDraft == false)
            #expect(reviewStatus == .changesRequested)
            #expect(ciStatus == .completedFailure)
        } else {
            Issue.record("Expected gitHubPullRequest kind for loaded GitHub item")
        }

        #expect(freshStore.selectedItemId == "gmail-snap-1")
    }

    @Test("Cold-start deserialization enforces 500-item cap on oversized snapshot file")
    func testLoadSnapshotEnforces500Cap() throws {
        let snapshotURL = getSnapshotURL()
        let backupData = try? Data(contentsOf: snapshotURL)
        defer {
            if let backupData {
                try? backupData.write(to: snapshotURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }

        // Generate oversized snapshot with 600 items each
        let oversizedGmail = (0..<600).map { i in
            makeTestItem(id: "snap-g-\(i)", source: .gmail, title: "Email \(i)")
        }
        let oversizedGitHub = (0..<600).map { i in
            makeTestItem(id: "snap-gh-\(i)", source: .gitHub, title: "PR \(i)")
        }

        let snapshot = SnapshotData(gmailItems: oversizedGmail, gitHubItems: oversizedGitHub, savedAt: Date())
        let data = try JSONEncoder().encode(snapshot)

        let dir = snapshotURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: snapshotURL, options: .atomic)

        let store = TriageStore()
        store.loadSnapshot()

        #expect(store.gmailItems.count == 500)
        #expect(store.gitHubItems.count == 500)
        #expect(store.gmailItems.first?.id == "snap-g-0")
        #expect(store.gmailItems.last?.id == "snap-g-499")
    }

    // MARK: - Navigation and Filter Tests

    @Test("Keyboard navigation selects next and previous items bounded by active list")
    func testKeyboardSelectionNavigation() {
        let store = TriageStore()
        let item1 = makeTestItem(id: "item-1", source: .gmail)
        let item2 = makeTestItem(id: "item-2", source: .gmail)
        let item3 = makeTestItem(id: "item-3", source: .gmail)

        store.setItems([item1, item2, item3], for: .gmail)
        #expect(store.selectedItemId == "item-1")

        store.selectNext()
        #expect(store.selectedItemId == "item-2")

        store.selectNext()
        #expect(store.selectedItemId == "item-3")

        // Boundary: cannot advance past end
        store.selectNext()
        #expect(store.selectedItemId == "item-3")

        store.selectPrevious()
        #expect(store.selectedItemId == "item-2")

        store.selectPrevious()
        #expect(store.selectedItemId == "item-1")

        // Boundary: cannot advance before start
        store.selectPrevious()
        #expect(store.selectedItemId == "item-1")
    }

    @Test("GitHub smart filters correctly isolate CI alerts, mentions, and review requests")
    func testGitHubSmartFilters() {
        let store = TriageStore()
        store.activeWorkspace = .gitHub

        let ciItem = TriageItem(
            id: "ci-1",
            source: .gitHub,
            title: "CI Failed",
            authorName: "bot",
            timestamp: Date(),
            tags: ["ci_activity"],
            kind: .gitHubNotification(threadId: "ci-1", reason: "ci_activity"),
            webURL: URL(string: "https://example.com/ci")!
        )

        let mentionItem = TriageItem(
            id: "mention-1",
            source: .gitHub,
            title: "Hey @dev",
            authorName: "peer",
            timestamp: Date(),
            tags: ["mention"],
            kind: .gitHubNotification(threadId: "m-1", reason: "mention"),
            webURL: URL(string: "https://example.com/mention")!
        )

        let reviewItem = TriageItem(
            id: "review-1",
            source: .gitHub,
            title: "Review requested",
            authorName: "peer",
            timestamp: Date(),
            tags: ["review_requested"],
            kind: .gitHubPullRequest(number: 10, repo: "r", isDraft: false, reviewStatus: .pending, ciStatus: .neutral),
            webURL: URL(string: "https://example.com/review")!
        )

        store.gitHubItems = [ciItem, mentionItem, reviewItem]

        store.gitHubFilter = .all
        #expect(store.filteredGitHubItems.count == 3)

        store.gitHubFilter = .ciAlerts
        #expect(store.filteredGitHubItems.count == 1)
        #expect(store.filteredGitHubItems.first?.id == "ci-1")

        store.gitHubFilter = .mentions
        #expect(store.filteredGitHubItems.count == 1)
        #expect(store.filteredGitHubItems.first?.id == "mention-1")

        store.gitHubFilter = .reviewRequests
        #expect(store.filteredGitHubItems.count == 1)
        #expect(store.filteredGitHubItems.first?.id == "review-1")
    }
}
