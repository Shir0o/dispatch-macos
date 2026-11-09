import Foundation
import Testing
@testable import DispatchApp

// MARK: - Mock URL Protocol for Network Isolation

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [RequestHandler] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
    }

    static func register(_ handler: @escaping RequestHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        let currentHandlers = MockURLProtocol.handlers
        MockURLProtocol.lock.unlock()

        for handler in currentHandlers {
            do {
                if let (response, data) = try handler(request) {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }

        // Default 404 fallback
        let url = request.url ?? URL(string: "https://mock.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"error\": \"not found\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Update Collector for Thread-Safe Concurrency

actor UpdateCollector {
    private(set) var updates: [([TriageItem], TriageSource)] = []

    func append(items: [TriageItem], source: TriageSource) {
        updates.append((items, source))
    }

    func count(for source: TriageSource) -> Int {
        updates.filter { $0.1 == source }.count
    }

    func lastItems(for source: TriageSource) -> [TriageItem]? {
        updates.last(where: { $0.1 == source })?.0
    }

    func reset() {
        updates.removeAll()
    }
}

// MARK: - Test Suite

@Suite("SyncCoordinator Tests")
struct SyncCoordinatorTests {

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeServices(session: URLSession) -> (GmailService, GitHubService) {
        let gmail = GmailService(session: session) {
            "mock-gmail-token"
        }
        let github = GitHubService(session: session) {
            "mock-github-token"
        }
        return (gmail, github)
    }

    // MARK: - JSON Fixture Helpers

    private func threadListJSON(threadIds: [(id: String, historyId: String)]) -> String {
        let entries = threadIds.map { "{\"id\": \"\($0.id)\", \"snippet\": \"Snippet for \($0.id)\", \"historyId\": \"\($0.historyId)\"}" }
        let joined = entries.joined(separator: ", ")
        return """
        {
            "threads": [\(joined)],
            "nextPageToken": null,
            "resultSizeEstimate": \(threadIds.count)
        }
        """
    }

    private func threadMetadataJSON(id: String, historyId: String, subject: String = "Test Subject") -> String {
        return """
        {
            "id": "\(id)",
            "historyId": "\(historyId)",
            "messages": [
                {
                    "id": "msg-\(id)",
                    "labelIds": ["INBOX", "UNREAD"],
                    "snippet": "Snippet for \(id)",
                    "internalDate": "1700000000000",
                    "payload": {
                        "headers": [
                            {"name": "Subject", "value": "\(subject)"},
                            {"name": "From", "value": "Sender <sender@example.com>"},
                            {"name": "Date", "value": "Mon, 1 Jan 2024 00:00:00 +0000"}
                        ]
                    }
                }
            ]
        }
        """
    }

    private func profileJSON(historyId: String) -> String {
        return """
        {
            "emailAddress": "user@example.com",
            "historyId": "\(historyId)",
            "messagesTotal": 100,
            "threadsTotal": 50
        }
        """
    }

    private func gitHubSearchIssuesJSON(issues: [(id: String, title: String, number: Int)]) -> String {
        let entries = issues.map { issue in
            """
            {
                "id": 1,
                "number": \(issue.number),
                "title": "\(issue.title)",
                "state": "open",
                "updated_at": "2024-01-01T12:00:00Z",
                "html_url": "https://github.com/owner/repo/issues/\(issue.number)",
                "user": {
                    "login": "owner",
                    "avatar_url": "https://avatars.githubusercontent.com/u/1"
                },
                "repository_url": "https://api.github.com/repos/owner/repo"
            }
            """
        }
        return "{\"total_count\": \(issues.count), \"items\": [\(entries.joined(separator: ", "))]}"
    }

    // MARK: - Tests

    @Test("Cold bootstrap sync sets initial historyId and ETag")
    func testColdBootstrapSync() async throws {
        MockURLProtocol.reset()
        let session = makeMockSession()
        let (gmail, github) = makeServices(session: session)

        // Mock Gmail endpoints
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("/profile") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(profileJSON(historyId: "1000").utf8))
            }
            if url.contains("/threads?") && url.contains("label:INBOX") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadListJSON(threadIds: [("thread-1", "1000")]).utf8))
            }
            if url.contains("/threads/thread-1?") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadMetadataJSON(id: "thread-1", historyId: "1000", subject: "Initial Thread").utf8))
            }
            return nil
        }

        // Mock GitHub assigned-issues search endpoint
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString, url.contains("api.github.com/search/issues") else { return nil }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "ETag": "W/\"gh-initial-etag\""
                ]
            )!
            let json = gitHubSearchIssuesJSON(issues: [("notif-1", "Assigned Issue", 101)])
            return (resp, Data(json.utf8))
        }

        let coordinator = SyncCoordinator(gmailService: gmail, gitHubService: github)
        let collector = UpdateCollector()

        await coordinator.setOnItemsUpdated { items, source in
            Task {
                await collector.append(items: items, source: source)
            }
        }

        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        // Verify status after bootstrap
        let status = await coordinator.getStatus()
        #expect(status.isRunning == true)
        #expect(status.lastGmailHistoryId == "1000")
        #expect(status.lastGitHubETag == "W/\"gh-initial-etag\"")

        // Wait briefly for asynchronous update emissions
        try await Task.sleep(nanoseconds: 50_000_000)
        let gmailCount = await collector.count(for: .gmail)
        let ghCount = await collector.count(for: .gitHub)
        #expect(gmailCount >= 1)
        #expect(ghCount >= 1)
    }

    @Test("Incremental polling delta logic updates historyId and reconciles added threads")
    func testIncrementalPollingDeltaLogic() async throws {
        MockURLProtocol.reset()
        let session = makeMockSession()
        let (gmail, github) = makeServices(session: session)

        // Step 1: Bootstrap setup
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("/profile") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(profileJSON(historyId: "1000").utf8))
            }
            if url.contains("/threads?") && url.contains("label:INBOX") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadListJSON(threadIds: [("thread-1", "1000")]).utf8))
            }
            if url.contains("/threads/thread-1?") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadMetadataJSON(id: "thread-1", historyId: "1000").utf8))
            }
            if url.contains("api.github.com/search/issues") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 304,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                return (resp, Data())
            }
            return nil
        }

        let coordinator = SyncCoordinator(gmailService: gmail, gitHubService: github)
        let collector = UpdateCollector()

        await coordinator.setOnItemsUpdated { items, source in
            Task {
                await collector.append(items: items, source: source)
            }
        }

        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        let initialHistory = await coordinator.lastGmailHistoryId
        #expect(initialHistory == "1000")

        // Step 2: Clear handlers and register incremental history and reconciliation responses
        MockURLProtocol.reset()

        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            // Incremental history endpoint: reports new historyId "1050" with added message in thread-2
            if url.contains("/history?") && url.contains("startHistoryId=1000") {
                let historyJSON = """
                {
                    "history": [
                        {
                            "id": "1001",
                            "messagesAdded": [
                                {
                                    "message": {
                                        "id": "msg-2",
                                        "threadId": "thread-2",
                                        "labelIds": ["INBOX"]
                                    }
                                }
                            ]
                        }
                    ],
                    "historyId": "1050"
                }
                """
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(historyJSON.utf8))
            }

            // Reconciliation fetchInboxThreads: returns thread-1 and thread-2
            if url.contains("/threads?") && url.contains("label:INBOX") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadListJSON(threadIds: [("thread-1", "1050"), ("thread-2", "1050")]).utf8))
            }

            if url.contains("/threads/thread-1?") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadMetadataJSON(id: "thread-1", historyId: "1050").utf8))
            }

            if url.contains("/threads/thread-2?") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadMetadataJSON(id: "thread-2", historyId: "1050", subject: "New Second Thread").utf8))
            }

            if url.contains("/profile") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(profileJSON(historyId: "1050").utf8))
            }

            if url.contains("api.github.com/search/issues") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }

            return nil
        }

        // Perform incremental sync cycle
        await collector.reset()
        await coordinator.performSyncCycle()

        let updatedHistory = await coordinator.lastGmailHistoryId
        #expect(updatedHistory == "1050")

        try await Task.sleep(nanoseconds: 50_000_000)
        let reconciledItems = await collector.lastItems(for: .gmail)
        #expect(reconciledItems?.count == 2)
        #expect(reconciledItems?.contains(where: { $0.id == "thread-2" }) == true)
    }

    @Test("HTTP 404 INVALID_HISTORY_ID triggers full inbox reconciliation and clears stale history ID")
    func testInvalidHistoryId404Recovery() async throws {
        MockURLProtocol.reset()
        let session = makeMockSession()
        let (gmail, github) = makeServices(session: session)

        // Bootstrap with history ID "999"
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("/profile") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(profileJSON(historyId: "999").utf8))
            }
            if url.contains("/threads?") && url.contains("label:INBOX") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadListJSON(threadIds: [("thread-stale", "999")]).utf8))
            }
            if url.contains("/threads/thread-stale?") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadMetadataJSON(id: "thread-stale", historyId: "999").utf8))
            }
            if url.contains("api.github.com/search/issues") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }
            return nil
        }

        let coordinator = SyncCoordinator(gmailService: gmail, gitHubService: github)
        let collector = UpdateCollector()

        await coordinator.setOnItemsUpdated { items, source in
            Task {
                await collector.append(items: items, source: source)
            }
        }

        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        #expect(await coordinator.lastGmailHistoryId == "999")

        // Now configure history endpoint to return HTTP 404 INVALID_HISTORY_ID
        MockURLProtocol.reset()
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            // Stale history query fails with HTTP 404
            if url.contains("/history?") {
                let errorBody = """
                {
                    "error": {
                        "code": 404,
                        "message": "INVALID_HISTORY_ID: historyId not found",
                        "status": "NOT_FOUND"
                    }
                }
                """
                let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(errorBody.utf8))
            }

            // Recovery reconciliation fetches full threads with fresh history ID "2000"
            if url.contains("/threads?") && url.contains("label:INBOX") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadListJSON(threadIds: [("thread-fresh", "2000")]).utf8))
            }

            if url.contains("/threads/thread-fresh?") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadMetadataJSON(id: "thread-fresh", historyId: "2000", subject: "Recovered Thread").utf8))
            }

            if url.contains("/profile") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(profileJSON(historyId: "2000").utf8))
            }

            if url.contains("api.github.com/search/issues") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }

            return nil
        }

        await collector.reset()
        // Execute sync cycle which will encounter 404 and recover
        await coordinator.performSyncCycle()

        // Verify recovered history ID
        let recoveredHistoryId = await coordinator.lastGmailHistoryId
        #expect(recoveredHistoryId == "2000")

        try await Task.sleep(nanoseconds: 50_000_000)
        let items = await collector.lastItems(for: .gmail)
        #expect(items?.count == 1)
        #expect(items?.first?.id == "thread-fresh")
        #expect(items?.first?.title == "Recovered Thread")
    }

    @Test("GitHub ETag 304 Not Modified caching retains ETag and consumes zero updates")
    func testGitHubETag304NotModifiedCaching() async throws {
        MockURLProtocol.reset()
        let session = makeMockSession()
        let (gmail, github) = makeServices(session: session)

        let initialETag = "W/\"etag-gh-release-12345\""

        // Step 1: Initial GitHub poll returns HTTP 200 with an ETag header
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("api.github.com/search/issues") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "ETag": initialETag
                    ]
                )!
                let json = gitHubSearchIssuesJSON(issues: [("gh-notif-1", "CI check failure", 42)])
                return (resp, Data(json.utf8))
            }

            if url.contains("/profile") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(profileJSON(historyId: "100").utf8))
            }
            if url.contains("/threads") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadListJSON(threadIds: []).utf8))
            }

            return nil
        }

        let coordinator = SyncCoordinator(gmailService: gmail, gitHubService: github)
        let collector = UpdateCollector()

        await coordinator.setOnItemsUpdated { items, source in
            Task {
                await collector.append(items: items, source: source)
            }
        }

        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        // Verify initial ETag cached
        #expect(await coordinator.lastGitHubETag == initialETag)

        // Step 2: Next poll sends If-None-Match with last ETag, server responds with HTTP 304
        MockURLProtocol.reset()
        nonisolated(unsafe) var receivedIfNoneMatch: String? = nil

        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("api.github.com/search/issues") {
                receivedIfNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 304,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                return (resp, Data())
            }

            if url.contains("/history?") {
                let historyJSON = "{\"history\": [], \"historyId\": \"100\"}"
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(historyJSON.utf8))
            }

            return nil
        }

        await collector.reset()
        await coordinator.performSyncCycle()

        // Verify request included If-None-Match
        #expect(receivedIfNoneMatch == initialETag)

        // Verify cached ETag was preserved
        #expect(await coordinator.lastGitHubETag == initialETag)

        // Verify NO github items were emitted on 304
        try await Task.sleep(nanoseconds: 50_000_000)
        let githubUpdates = await collector.count(for: .gitHub)
        #expect(githubUpdates == 0)
    }

    @Test("GitHub ETag updates when server returns 200 with new content and new ETag")
    func testGitHubETagUpdatesOnNewContent() async throws {
        MockURLProtocol.reset()
        let session = makeMockSession()
        let (gmail, github) = makeServices(session: session)

        // Initial 200 with etag-1
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("api.github.com/search/issues") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "ETag": "W/\"etag-v1\""]
                )!
                return (resp, Data(gitHubSearchIssuesJSON(issues: [("notif-1", "First Notif", 1)]).utf8))
            }
            if url.contains("/profile") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(profileJSON(historyId: "100").utf8))
            }
            if url.contains("/threads") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data(threadListJSON(threadIds: []).utf8))
            }
            return nil
        }

        let coordinator = SyncCoordinator(gmailService: gmail, gitHubService: github)
        let collector = UpdateCollector()

        await coordinator.setOnItemsUpdated { items, source in
            Task {
                await collector.append(items: items, source: source)
            }
        }

        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        #expect(await coordinator.lastGitHubETag == "W/\"etag-v1\"")

        // Next poll returns 200 with etag-2 and updated notification
        MockURLProtocol.reset()
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("api.github.com/search/issues") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "ETag": "W/\"etag-v2\""]
                )!
                return (resp, Data(gitHubSearchIssuesJSON(issues: [("notif-2", "Second Notif", 2)]).utf8))
            }
            if url.contains("/history?") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (resp, Data("{\"history\": [], \"historyId\": \"100\"}".utf8))
            }
            return nil
        }

        await collector.reset()
        await coordinator.performSyncCycle()

        #expect(await coordinator.lastGitHubETag == "W/\"etag-v2\"")

        try await Task.sleep(nanoseconds: 50_000_000)
        let updatedItems = await collector.lastItems(for: .gitHub)
        #expect(updatedItems?.count == 1)
        #expect(updatedItems?.first?.id == "owner/repo#2")
    }

    @Test("System sleep and wake transitions manage polling state properly")
    func testSystemSleepAndWake() async throws {
        let session = makeMockSession()
        let (gmail, github) = makeServices(session: session)

        let coordinator = SyncCoordinator(gmailService: gmail, gitHubService: github)
        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        var status = await coordinator.getStatus()
        #expect(status.isRunning == true)
        #expect(status.isSleeping == false)

        await coordinator.handleSystemWillSleep()
        status = await coordinator.getStatus()
        #expect(status.isSleeping == true)

        await coordinator.handleSystemDidWake()
        status = await coordinator.getStatus()
        #expect(status.isSleeping == false)
    }

    @Test("Network availability changes suspend and resume sync operations")
    func testNetworkStatusTransitions() async throws {
        let session = makeMockSession()
        let (gmail, github) = makeServices(session: session)

        let coordinator = SyncCoordinator(gmailService: gmail, gitHubService: github)
        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        var status = await coordinator.getStatus()
        #expect(status.isNetworkAvailable == true)

        await coordinator.updateNetworkStatus(isAvailable: false)
        status = await coordinator.getStatus()
        #expect(status.isNetworkAvailable == false)

        await coordinator.updateNetworkStatus(isAvailable: true)
        status = await coordinator.getStatus()
        #expect(status.isNetworkAvailable == true)
    }
}
