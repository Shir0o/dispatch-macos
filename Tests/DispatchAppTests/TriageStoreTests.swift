import Foundation
import Testing
@testable import DispatchApp

@Suite("TriageStore Tests", .serialized)
@MainActor
struct TriageStoreTests {

    // MARK: - Helper Functions

    private func makeTestItem(
        id: String,
        title: String = "Test Item",
        isUnread: Bool = true,
        tags: [String] = []
    ) -> TriageItem {
        TriageItem(
            id: id,
            source: .gmail,
            title: title,
            authorName: "Author \(id)",
            authorAvatarURL: nil,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            isUnread: isUnread,
            isStarred: false,
            isArchived: false,
            tags: tags,
            kind: .email(threadId: id, snippet: "Snippet for \(id)", hasHtml: false),
            webURL: URL(string: "https://example.com/\(id)")!
        )
    }

    private func getSnapshotURL() -> URL {
        TriageStore.defaultSnapshotURL
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Backs up the snapshot file for the duration of a test and restores it.
    private func withSnapshotBackup(_ body: () throws -> Void) rethrows {
        let snapshotURL = getSnapshotURL()
        let backupData = try? Data(contentsOf: snapshotURL)
        defer {
            if let backupData {
                try? backupData.write(to: snapshotURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }
        try body()
    }

    private func writeRawSnapshot(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try writeData(data, to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    private func directoryContents() -> Set<String> {
        let dir = getSnapshotURL().deletingLastPathComponent()
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    // MARK: - 500-Item Prefix Capping Tests

    @Test("Direct assignment to gmailItems caps at 500 elements")
    func testGmailItemsDirectAssignmentCapping() {
        let store = TriageStore()
        let items = (0..<600).map { i in
            makeTestItem(id: "gmail-\(i)", title: "Email \(i)")
        }

        store.gmailItems = items

        #expect(store.gmailItems.count == 500)
        #expect(store.gmailItems.first?.id == "gmail-0")
        #expect(store.gmailItems.last?.id == "gmail-499")
    }

    @Test("setItems caps Gmail items at 500 elements and preserves item ordering")
    func testSetItemsGmailCapping() {
        let store = TriageStore()
        let items = (0..<750).map { i in
            makeTestItem(id: "gmail-bulk-\(i)", title: "Thread \(i)")
        }

        store.setItems(items, for: .gmail)

        #expect(store.gmailItems.count == 500)
        #expect(store.gmailItems[0].id == "gmail-bulk-0")
        #expect(store.gmailItems[499].id == "gmail-bulk-499")
        #expect(store.selectedItemId == "gmail-bulk-0")
    }

    @Test("Items below 500 are fully preserved without capping")
    func testItemsBelow500Preserved() {
        let store = TriageStore()
        let count = 42
        let items = (0..<count).map { i in
            makeTestItem(id: "item-\(i)", title: "Item \(i)")
        }

        store.gmailItems = items
        #expect(store.gmailItems.count == count)
        #expect(store.unreadCount(for: .gmail) == count)
    }

    // MARK: - GitHub Fallbacks

    @Test("The GitHub workspace has no items and no unread count; selection stays Gmail-only")
    func testGitHubWorkspaceFallbacks() {
        let store = TriageStore()
        let item = makeTestItem(id: "gmail-1", title: "Only Gmail")
        store.setItems([item], for: .gmail)
        #expect(store.selectedItemId == "gmail-1")

        store.activeWorkspace = .gitHub

        #expect(store.activeItems.isEmpty)
        #expect(store.unreadCount(for: .gitHub) == 0)
        // There is no GitHub fallback: the selection still resolves to the Gmail item.
        #expect(store.selectedItem?.id == "gmail-1")

        store.activeWorkspace = .gmail
        #expect(store.activeItems.map(\.id) == ["gmail-1"])
        #expect(store.selectedItem?.id == "gmail-1")

        // A stale selection id resolves to nothing rather than a GitHub item.
        store.selectedItemId = "gh-not-a-gmail-item"
        #expect(store.selectedItem == nil)
    }

    @Test("setItems(.gitHub) is a no-op and does not disturb Gmail state")
    func testSetItemsGitHubIsNoOp() {
        let store = TriageStore()
        let gmailItem = makeTestItem(id: "gmail-1")
        store.setItems([gmailItem], for: .gmail)

        let githubLike = makeTestItem(id: "gmail-2", title: "Decoy")
        store.setItems([githubLike], for: .gitHub)

        #expect(store.gmailItems.map(\.id) == ["gmail-1"])
        #expect(store.selectedItemId == "gmail-1")
    }

    // MARK: - Optimistic Archive Deletion & Rollback Tests

    @Test("Optimistic archive immediately removes Gmail item and rolls back on service failure")
    func testGmailArchiveOptimisticDeletionAndRollback() async throws {
        let store = TriageStore()

        let item0 = makeTestItem(id: "g0", title: "First")
        let item1 = makeTestItem(id: "g1", title: "Target to Archive")
        let item2 = makeTestItem(id: "g2", title: "Third")
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
        let item = makeTestItem(id: "g-alone", title: "Alone")
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

    @Test("Successful archive keeps item removed and does not trigger rollback")
    func testSuccessfulArchiveMaintainsDeletion() async throws {
        let store = TriageStore()

        let item0 = makeTestItem(id: "g0", title: "Keep")
        let item1 = makeTestItem(id: "g1", title: "Archive Me")
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

    @Test("Trash is Gmail-only")
    func testTrashIsGmailOnly() {
        let store = TriageStore()
        let gmailItem = makeTestItem(id: "g1")
        store.gmailItems = [gmailItem]

        // A Gmail-kind item from another source is a no-op: no removal, no toast.
        let foreign = TriageItem(
            id: "foreign-1",
            source: .gitHub,
            title: "Retired GitHub item",
            authorName: "ghost",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            kind: .email(threadId: "foreign-1", snippet: "", hasHtml: false),
            webURL: URL(string: "https://example.com/foreign-1")!
        )

        store.trash(item: foreign)
        store.archive(item: foreign)
        store.markUnread(item: foreign)

        #expect(store.gmailItems.map(\.id) == ["g1"])
        #expect(store.toastMessage == nil)
    }

    // MARK: - Snapshot Persistence Tests

    @Test("Synchronous atomic snapshot serialization and cold-start deserialization")
    func testSnapshotSaveAndLoad() throws {
        try withSnapshotBackup {
            let snapshotURL = getSnapshotURL()

            let store = TriageStore()
            let gmailItem = makeTestItem(
                id: "gmail-snap-1",
                title: "Architecture Discussion",
                isUnread: true,
                tags: ["INBOX", "IMPORTANT"]
            )

            store.gmailItems = [gmailItem]

            // Save synchronously
            store.saveSnapshotSync()

            #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

            // Verify snapshot file decodes valid SnapshotData and writes no GitHub state.
            let fileData = try Data(contentsOf: snapshotURL)
            let decoded = try JSONDecoder().decode(SnapshotData.self, from: fileData)
            #expect(decoded.gmailItems.count == 1)
            #expect(decoded.gitHubItems.isEmpty)
            #expect(decoded.dismissedGitHubKeys == nil)

            // Cold-start with fresh store
            let freshStore = TriageStore()
            #expect(freshStore.gmailItems.isEmpty)

            freshStore.loadSnapshot()

            #expect(freshStore.gmailItems.count == 1)

            let loadedGmail = freshStore.gmailItems.first
            #expect(loadedGmail?.id == "gmail-snap-1")
            #expect(loadedGmail?.title == "Architecture Discussion")
            #expect(loadedGmail?.tags == ["INBOX", "IMPORTANT"])
            #expect(loadedGmail?.isUnread == true)
            #expect(freshStore.selectedItemId == "gmail-snap-1")
        }
    }

    @Test("Cold-start deserialization enforces 500-item cap on oversized snapshot file")
    func testLoadSnapshotEnforces500Cap() throws {
        try withSnapshotBackup {
            let snapshotURL = getSnapshotURL()

            // Generate oversized snapshot
            let oversizedGmail = (0..<600).map { i in
                makeTestItem(id: "snap-g-\(i)", title: "Email \(i)")
            }

            let snapshot = SnapshotData(gmailItems: oversizedGmail, gitHubItems: [], savedAt: Date())
            let data = try JSONEncoder().encode(snapshot)
            try writeData(data, to: snapshotURL)

            let store = TriageStore()
            store.loadSnapshot()

            #expect(store.gmailItems.count == 500)
            #expect(store.gmailItems.first?.id == "snap-g-0")
            #expect(store.gmailItems.last?.id == "snap-g-499")
        }
    }

    @Test("An old snapshot with GitHub fields still loads its Gmail items")
    func testOldSnapshotWithGitHubFieldsLoadsGmail() throws {
        try withSnapshotBackup {
            let snapshotURL = getSnapshotURL()
            let contentsBefore = directoryContents()
            let gmailItem = makeTestItem(id: "gmail-legacy-1", title: "Survivor", isUnread: true)

            let gmailJSON = try JSONEncoder().encode([gmailItem])
            let gmailObjects = try JSONSerialization.jsonObject(with: gmailJSON)

            // A retired GitHub item shape that the current TriageKind cannot decode.
            let legacyGitHubItem: [String: Any] = [
                "id": "owner/repo#1",
                "source": "gitHub",
                "title": "Retired issue",
                "authorName": "octocat",
                "timestamp": Date().timeIntervalSinceReferenceDate,
                "isUnread": false,
                "isStarred": false,
                "isArchived": false,
                "tags": ["mention"],
                "kind": [
                    "gitHubIssue": [
                        "number": 1,
                        "repo": "owner/repo",
                        "state": "open",
                        "isAssignedToMe": true
                    ]
                ],
                "webURL": "https://github.com/owner/repo/issues/1"
            ]

            let object: [String: Any] = [
                "gmailItems": gmailObjects,
                "gitHubItems": [legacyGitHubItem],
                "savedAt": Date().timeIntervalSinceReferenceDate,
                "dismissedGitHubKeys": ["owner/repo#1"]
            ]
            try writeRawSnapshot(object, to: snapshotURL)

            let store = TriageStore()
            store.loadSnapshot()

            #expect(store.gmailItems.map(\.id) == ["gmail-legacy-1"])
            #expect(store.selectedItemId == "gmail-legacy-1")
            #expect(store.activeItems.count == 1)

            // The old file is read, not quarantined.
            #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
            let newNames = directoryContents().subtracting(contentsBefore)
            let quarantined = newNames.filter { $0.hasPrefix("snapshot.corrupt-") }
            #expect(quarantined.isEmpty)
        }
    }

    @Test("A corrupt snapshot is quarantined, does not block the next save, and starts clean")
    func testCorruptSnapshotIsQuarantined() throws {
        let snapshotURL = getSnapshotURL()
        let backupData = try? Data(contentsOf: snapshotURL)
        let contentsBefore = directoryContents()

        defer {
            // Restore the original snapshot and remove the quarantine copy.
            if let backupData {
                try? backupData.write(to: snapshotURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            let contentsAfter = directoryContents()
            for name in contentsAfter.subtracting(contentsBefore)
            where name.hasPrefix("snapshot.corrupt-") && name.hasSuffix(".json") {
                try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent().appendingPathComponent(name))
            }
        }

        let dir = snapshotURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{ this is not a snapshot".utf8).write(to: snapshotURL, options: .atomic)

        let store = TriageStore()
        store.gmailItems = [makeTestItem(id: "before-corruption")]

        store.loadSnapshot()

        // Empty Gmail state, no selection, original file moved aside.
        #expect(store.gmailItems.isEmpty)
        #expect(store.selectedItemId == nil)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))

        let newNames = directoryContents().subtracting(contentsBefore)
        let quarantined = newNames.filter { $0.hasPrefix("snapshot.corrupt-") && $0.hasSuffix(".json") }
        #expect(quarantined.count == 1)

        // The next save is allowed and writes a fresh snapshot.
        store.gmailItems = [makeTestItem(id: "after-corruption")]
        store.saveSnapshotSync()

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        let decoded = try SnapshotData.load(from: snapshotURL)
        #expect(decoded.gmailItems.map(\.id) == ["after-corruption"])
    }

    @Test("A missing snapshot is skipped and the next save still writes one")
    func testMissingSnapshotStillSaves() throws {
        try withSnapshotBackup {
            let snapshotURL = getSnapshotURL()
            try? FileManager.default.removeItem(at: snapshotURL)

            let store = TriageStore()
            let item = makeTestItem(id: "gmail-missing-1")
            store.gmailItems = [item]

            store.loadSnapshot()
            #expect(store.gmailItems.map(\.id) == ["gmail-missing-1"])

            store.saveSnapshotSync()

            #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
            let decoded = try SnapshotData.load(from: snapshotURL)
            #expect(decoded.gmailItems.map(\.id) == ["gmail-missing-1"])
        }
    }

    // MARK: - Navigation Tests

    @Test("Keyboard navigation selects next and previous items bounded by active list")
    func testKeyboardSelectionNavigation() {
        let store = TriageStore()
        let item1 = makeTestItem(id: "item-1")
        let item2 = makeTestItem(id: "item-2")
        let item3 = makeTestItem(id: "item-3")

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
}
