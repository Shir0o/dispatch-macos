import Foundation
import Testing
@testable import DispatchApp

// MARK: - Request Recorder

/// Thread-safe record of the URLs the service actually requested.
private final class OpenWorkRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(url)
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        urls.count
    }
}

// MARK: - Mock Page & Fixtures

private let openWorkSearchPath = "/search/issues"

private func openWorkSearchPageURL(page: Int) -> String {
    "https://api.github.com/search/issues"
        + "?q=is%3Aopen%20involves%3A%40me&sort=updated&order=desc&per_page=100&page=\(page)"
}

private struct OpenWorkMockPage: Sendable {
    let body: String
    let status: Int
    let next: Int?
    let headers: [String: String]

    init(
        body: String,
        status: Int = 200,
        next: Int? = nil,
        headers: [String: String] = [:]
    ) {
        self.body = body
        self.status = status
        self.next = next
        self.headers = headers
    }
}

private func makeIssueJSON(
    number: Int,
    repository: String = "owner/repo",
    title: String = "Issue",
    login: String? = "octocat",
    updatedAt: String = "2024-01-01T12:00:00Z",
    isPullRequest: Bool = false,
    htmlURL: String? = nil,
    repositoryURL: String? = nil
) -> String {
    let user = login.map { "{\"login\": \"\($0)\", \"avatar_url\": null}" } ?? "null"
    let pullRequest = isPullRequest
        ? "{\"url\": \"https://api.github.com/repos/\(repository)/pulls/\(number)\"}"
        : "null"
    let html = htmlURL ?? "https://github.com/\(repository)/\(isPullRequest ? "pull" : "issues")/\(number)"
    let repositoryURL = repositoryURL ?? "https://api.github.com/repos/\(repository)"

    return """
    {
        "number": \(number),
        "title": "\(title)",
        "state": "open",
        "draft": null,
        "user": \(user),
        "labels": [],
        "assignees": [],
        "updated_at": "\(updatedAt)",
        "html_url": "\(html)",
        "repository_url": "\(repositoryURL)",
        "pull_request": \(pullRequest)
    }
    """
}

private func makeSearchJSON(totalCount: Int, items: [String]) -> String {
    """
    {
        "total_count": \(totalCount),
        "incomplete_results": false,
        "items": [\(items.joined(separator: ","))]
    }
    """
}

private func makeItemsPage(
    page: Int,
    count: Int,
    totalCount: Int,
    next: Int?
) -> OpenWorkMockPage {
    let items = (0..<count).map { index in
        makeIssueJSON(number: (page - 1) * 100 + index + 1)
    }
    return OpenWorkMockPage(
        body: makeSearchJSON(totalCount: totalCount, items: items),
        next: next
    )
}

// MARK: - Mock Registration

private func registerOpenWorkPages(
    recorder: OpenWorkRequestRecorder,
    pages: [Int: OpenWorkMockPage],
    fallback: OpenWorkMockPage? = nil
) {
    MockURLProtocol.register { request in
        guard let url = request.url, url.path == openWorkSearchPath else { return nil }
        recorder.record(url)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pageValue = components?.queryItems?.first(where: { $0.name == "page" })?.value
        let pageNumber = pageValue.flatMap(Int.init) ?? 1

        guard let page = pages[pageNumber] ?? fallback else { return nil }

        var headers = page.headers
        if let next = page.next {
            headers["Link"] = "<\(openWorkSearchPageURL(page: next))>; rel=\"next\""
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: page.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else { return nil }

        return (response, Data(page.body.utf8))
    }
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeService(
    session: URLSession,
    tokenProvider: @escaping @Sendable () async throws -> String = { "mock-github-token" }
) -> GitHubService {
    GitHubService(session: session, tokenProvider: tokenProvider)
}

private func fetchError(_ service: GitHubService) async -> OpenWorkFetchError? {
    do {
        _ = try await service.fetchOpenWork()
        return nil
    } catch let error as OpenWorkFetchError {
        return error
    } catch {
        Issue.record("Expected OpenWorkFetchError, got \(error)")
        return nil
    }
}

// MARK: - Test Suite

@Suite("Open Work Fetch Tests", .serialized)
struct OpenWorkFetchTests {

    @Test("One page maps items, total_count and the query contract")
    func onePageMapsItemsAndQueryContract() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let body = makeSearchJSON(totalCount: 2, items: [
            makeIssueJSON(
                number: 12,
                repository: "Owner/Repo",
                title: "Crash on launch",
                login: "octocat"
            ),
            makeIssueJSON(
                number: 34,
                title: "Add open work",
                login: "hubot",
                updatedAt: "2024-01-05T10:00:00Z",
                isPullRequest: true
            )
        ])
        registerOpenWorkPages(recorder: recorder, pages: [1: OpenWorkMockPage(body: body)])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.items.count == 2)
        #expect(result.matchedCount == 2)
        #expect(result.fetchedCount == 2)
        #expect(result.truncated == false)
        #expect(result.complete == true)
        #expect(recorder.count == 1)

        let url = try #require(recorder.urls.first)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == openWorkSearchPath)

        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["q"] == "is:open involves:@me")
        #expect(query["sort"] == "updated")
        #expect(query["order"] == "desc")
        #expect(query["per_page"] == "100")

        let issue = try #require(result.items.first)
        #expect(issue.key == "owner/repo#12")
        #expect(issue.repository == "Owner/Repo")
        #expect(issue.kind == .issue)
        #expect(issue.authorLogin == "octocat")
        #expect(issue.webURL.absoluteString == "https://github.com/Owner/Repo/issues/12")
        #expect(result.items[1].kind == .pullRequest)
        #expect(result.items[1].updatedAt > issue.updatedAt)
    }

    @Test("Follows the next link across multiple pages")
    func followsNextLink() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let pageOne = OpenWorkMockPage(
            body: makeSearchJSON(totalCount: 150, items: [
                makeIssueJSON(number: 1),
                makeIssueJSON(number: 2)
            ]),
            next: 2
        )
        let pageTwo = OpenWorkMockPage(
            body: makeSearchJSON(totalCount: 150, items: [makeIssueJSON(number: 3)])
        )
        registerOpenWorkPages(recorder: recorder, pages: [1: pageOne, 2: pageTwo])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.items.count == 3)
        #expect(result.matchedCount == 150)
        #expect(result.fetchedCount == 3)
        #expect(result.truncated == false)
        #expect(result.complete == true)
        #expect(recorder.count == 2)

        let secondURL = try #require(recorder.urls.last)
        let components = try #require(URLComponents(url: secondURL, resolvingAgainstBaseURL: false))
        let pageValue = components.queryItems?.first(where: { $0.name == "page" })?.value
        #expect(pageValue == "2")
    }

    @Test("A matched count above 400 is truncated even without a next link")
    func matchedCountAboveCapIsTruncated() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let body = makeSearchJSON(totalCount: 512, items: [makeIssueJSON(number: 1)])
        registerOpenWorkPages(recorder: recorder, pages: [1: OpenWorkMockPage(body: body)])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.matchedCount == 512)
        #expect(result.truncated == true)
        #expect(result.complete == false)
    }

    @Test("Duplicate keys across pages keep the first occurrence")
    func deduplicatesAcrossPages() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let pageOne = OpenWorkMockPage(
            body: makeSearchJSON(totalCount: 2, items: [
                makeIssueJSON(number: 1, title: "First occurrence")
            ]),
            next: 2
        )
        let pageTwo = OpenWorkMockPage(
            body: makeSearchJSON(totalCount: 2, items: [
                makeIssueJSON(
                    number: 1,
                    repository: "OWNER/REPO",
                    title: "Duplicate occurrence",
                    repositoryURL: "https://api.github.com/repos/OWNER/REPO"
                ),
                makeIssueJSON(number: 2, title: "Second item")
            ])
        )
        registerOpenWorkPages(recorder: recorder, pages: [1: pageOne, 2: pageTwo])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.items.count == 2)
        #expect(result.fetchedCount == 2)
        #expect(Set(result.items.map(\.key)) == ["owner/repo#1", "owner/repo#2"])
        #expect(result.items.first?.title == "First occurrence")
    }

    @Test("Exactly 400 items across four pages is complete")
    func exactlyFourHundredIsComplete() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        registerOpenWorkPages(recorder: recorder, pages: [
            1: makeItemsPage(page: 1, count: 100, totalCount: 400, next: 2),
            2: makeItemsPage(page: 2, count: 100, totalCount: 400, next: 3),
            3: makeItemsPage(page: 3, count: 100, totalCount: 400, next: 4),
            4: makeItemsPage(page: 4, count: 100, totalCount: 400, next: nil)
        ])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.items.count == 400)
        #expect(result.fetchedCount == 400)
        #expect(result.matchedCount == 400)
        #expect(result.truncated == false)
        #expect(result.complete == true)
        #expect(recorder.count == 4)
    }

    @Test("Page four advertising a next link is truncated after four pages")
    func pageFourNextLinkIsTruncated() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        registerOpenWorkPages(recorder: recorder, pages: [
            1: makeItemsPage(page: 1, count: 100, totalCount: 400, next: 2),
            2: makeItemsPage(page: 2, count: 100, totalCount: 400, next: 3),
            3: makeItemsPage(page: 3, count: 100, totalCount: 400, next: 4),
            4: makeItemsPage(page: 4, count: 100, totalCount: 400, next: 5)
        ])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.items.count == 400)
        #expect(result.truncated == true)
        #expect(result.complete == false)
        #expect(recorder.count == 4)
    }

    @Test("A 404 on page two throws notFound and never becomes an empty success")
    func pageTwoNotFoundThrows() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let pageOne = OpenWorkMockPage(
            body: makeSearchJSON(totalCount: 2, items: [makeIssueJSON(number: 1)]),
            next: 2
        )
        let pageTwo = OpenWorkMockPage(body: "{\"message\": \"Not Found\"}", status: 404)
        registerOpenWorkPages(recorder: recorder, pages: [1: pageOne, 2: pageTwo])

        let error = await fetchError(makeService(session: makeSession()))

        #expect(error == .notFound)
        #expect(recorder.count == 2)
    }

    @Test("401 maps to unauthorized")
    func unauthorized() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        registerOpenWorkPages(
            recorder: recorder,
            pages: [1: OpenWorkMockPage(body: "{\"message\": \"Bad credentials\"}", status: 401)]
        )

        let error = await fetchError(makeService(session: makeSession()))

        #expect(error == .unauthorized)
    }

    @Test("403 maps to forbidden with the rate-limit reset time")
    func forbiddenWithReset() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let resetEpoch = 1_700_000_000.0
        registerOpenWorkPages(recorder: recorder, pages: [
            1: OpenWorkMockPage(
                body: "{\"message\": \"rate limit\"}",
                status: 403,
                headers: ["x-ratelimit-reset": String(Int(resetEpoch))]
            )
        ])

        let error = await fetchError(makeService(session: makeSession()))

        #expect(error == .forbidden(resetAt: Date(timeIntervalSince1970: resetEpoch)))
    }

    @Test("5xx maps to server with the status code")
    func serverError() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        registerOpenWorkPages(
            recorder: recorder,
            pages: [1: OpenWorkMockPage(body: "{\"message\": \"boom\"}", status: 503)]
        )

        let error = await fetchError(makeService(session: makeSession()))

        #expect(error == .server(status: 503))
    }

    @Test("Malformed JSON maps to decoding")
    func malformedJSON() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        registerOpenWorkPages(
            recorder: recorder,
            pages: [1: OpenWorkMockPage(body: "{not valid json")]
        )

        let error = await fetchError(makeService(session: makeSession()))

        #expect(error == .decoding)
    }

    @Test("A URL error maps to transport")
    func urlErrorMapsToTransport() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register { _ in
            throw URLError(.notConnectedToInternet)
        }

        let error = await fetchError(makeService(session: makeSession()))

        #expect(error == .transport)
    }

    @Test("A missing token maps to notConfigured without a request")
    func missingToken() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        registerOpenWorkPages(
            recorder: recorder,
            pages: [1: OpenWorkMockPage(body: makeSearchJSON(totalCount: 0, items: []))]
        )

        let service = makeService(session: makeSession()) {
            throw GitHubError.missingToken
        }
        let error = await fetchError(service)

        #expect(error == .notConfigured)
        #expect(recorder.count == 0)
    }

    @Test("A Keychain failure maps to notConfigured")
    func keychainFailure() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        registerOpenWorkPages(
            recorder: recorder,
            pages: [1: OpenWorkMockPage(body: makeSearchJSON(totalCount: 0, items: []))]
        )

        let service = makeService(session: makeSession()) {
            throw AuthError.keychainError(status: -25300)
        }
        let error = await fetchError(service)

        #expect(error == .notConfigured)
        #expect(recorder.count == 0)
    }

    @Test("A nil author becomes ghost")
    func nilAuthorBecomesGhost() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let body = makeSearchJSON(
            totalCount: 1,
            items: [makeIssueJSON(number: 7, login: nil)]
        )
        registerOpenWorkPages(recorder: recorder, pages: [1: OpenWorkMockPage(body: body)])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.items.count == 1)
        #expect(result.items.first?.authorLogin == "ghost")
    }

    @Test("Records with an unparsable repository or html URL are skipped")
    func invalidURLsAreSkipped() async throws {
        MockURLProtocol.reset()
        let recorder = OpenWorkRequestRecorder()
        let body = makeSearchJSON(totalCount: 3, items: [
            makeIssueJSON(number: 1),
            makeIssueJSON(number: 2, repositoryURL: "invalid"),
            makeIssueJSON(number: 3, htmlURL: "http://[invalid")
        ])
        registerOpenWorkPages(recorder: recorder, pages: [1: OpenWorkMockPage(body: body)])

        let result = try await makeService(session: makeSession()).fetchOpenWork()

        #expect(result.matchedCount == 3)
        #expect(result.items.count == 1)
        #expect(result.fetchedCount == 1)
        #expect(result.items.first?.number == 1)
        #expect(result.complete == true)
    }
}
