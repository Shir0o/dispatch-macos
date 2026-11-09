import Foundation
import Testing
@testable import DispatchApp

@Suite("GitHub Backfill Tests")
struct GitHubBackfillTests {

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeService(session: URLSession) -> GitHubService {
        GitHubService(session: session) { "mock-github-token" }
    }

    private func openWorkJSON() -> String {
        """
        [
            {
                "number": 12,
                "title": "Crash on launch",
                "state": "open",
                "draft": null,
                "user": {
                    "login": "octocat",
                    "avatar_url": "https://avatars.githubusercontent.com/u/1"
                },
                "labels": [{"name": "bug"}, {"name": "p1"}],
                "assignees": [{"login": "me", "avatar_url": null}],
                "created_at": "2024-01-01T10:00:00Z",
                "updated_at": "2024-01-03T10:00:00Z",
                "html_url": "https://github.com/owner/repo/issues/12",
                "repository_url": "https://api.github.com/repos/owner/repo",
                "pull_request": null
            },
            {
                "number": 34,
                "title": "Add open work backfill",
                "state": "open",
                "draft": true,
                "user": {
                    "login": "hubot",
                    "avatar_url": null
                },
                "labels": [],
                "assignees": [],
                "created_at": "2024-01-02T10:00:00Z",
                "updated_at": "2024-01-05T10:00:00Z",
                "html_url": "https://github.com/owner/repo/pull/34",
                "repository_url": "https://api.github.com/repos/owner/repo",
                "pull_request": {"url": "https://api.github.com/repos/owner/repo/pulls/34"}
            }
        ]
        """
    }

    // MARK: - Service

    @Test("Backfill maps open issues and pull requests into triage items")
    func testFetchOpenIssuesAndPullRequestsMapping() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString,
                  url.contains("api.github.com/repos/owner/repo/issues?state=open") else { return nil }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(openWorkJSON().utf8))
        }

        let service = makeService(session: makeMockSession())
        let items = try await service.fetchOpenIssuesAndPullRequests(
            repositories: ["owner/repo"],
            login: "me"
        )

        #expect(items.count == 2)

        // Newest update first: the pull request was updated later than the issue.
        #expect(items[0].id == "gh:pr:owner/repo#34")
        #expect(items[0].title == "Add open work backfill")
        #expect(items[0].authorName == "hubot")
        #expect(items[0].isUnread == false)
        #expect(items[0].isBackfillDerived == true)
        #expect(items[0].webURL.absoluteString == "https://github.com/owner/repo/pull/34")

        if case .gitHubPullRequest(let number, let repo, let isDraft, _, _) = items[0].kind {
            #expect(number == 34)
            #expect(repo == "owner/repo")
            #expect(isDraft == true)
        } else {
            Issue.record("Expected gitHubPullRequest kind for backfilled pull request")
        }

        #expect(items[1].id == "gh:issue:owner/repo#12")
        #expect(items[1].tags == ["bug", "p1"])

        if case .gitHubIssue(let number, let repo, let state, let assigned) = items[1].kind {
            #expect(number == 12)
            #expect(repo == "owner/repo")
            #expect(state == "open")
            #expect(assigned == true)
        } else {
            Issue.record("Expected gitHubIssue kind for backfilled issue")
        }
    }

    @Test("Backfill without repositories queries every open issue the user is involved with")
    func testFetchOpenWorkFallsBackToInvolvementScope() async throws {
        MockURLProtocol.reset()
        nonisolated(unsafe) var requestedURL: String?

        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString,
                  url.contains("api.github.com/issues?") else { return nil }
            requestedURL = url
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("[]".utf8))
        }

        let service = makeService(session: makeMockSession())
        let items = try await service.fetchOpenIssuesAndPullRequests(
            repositories: ["   ", "not-a-repo"],
            login: nil
        )

        #expect(items.isEmpty)
        #expect(requestedURL?.contains("filter=all") == true)
        #expect(requestedURL?.contains("state=open") == true)
    }

    @Test("Repository normalization drops blanks, malformed entries, and duplicates")
    func testNormalizeRepositories() {
        let normalized = GitHubService.normalizeRepositories([
            " owner/repo ",
            "owner/repo",
            "OWNER/Repo/extra",
            "",
            "single",
            "other/project"
        ])

        #expect(normalized == ["owner/repo", "other/project"])
    }

    // MARK: - Store Integration

    private func makeIssueItem(
        id: String,
        number: Int,
        repo: String = "owner/repo",
        title: String = "Issue"
    ) -> TriageItem {
        TriageItem(
            id: id,
            source: .gitHub,
            title: title,
            authorName: "octocat",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            isUnread: false,
            kind: .gitHubIssue(number: number, repo: repo, state: "open", isAssignedToMe: false),
            webURL: URL(string: "https://github.com/\(repo)/issues/\(number)")!
        )
    }

    private func makeNotificationItem(
        id: String,
        number: Int,
        repo: String = "owner/repo",
        title: String = "Notification"
    ) -> TriageItem {
        TriageItem(
            id: id,
            source: .gitHub,
            title: title,
            authorName: repo,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            isUnread: true,
            kind: .gitHubIssue(number: number, repo: repo, state: "open", isAssignedToMe: true),
            webURL: URL(string: "https://github.com/\(repo)/issues/\(number)")!
        )
    }

    @Test("Backfilled open work is retained when the live notification feed refreshes")
    @MainActor
    func testBackfillSurvivesNotificationRefresh() {
        let store = TriageStore()
        let backfill = makeIssueItem(id: "gh:issue:owner/repo#7", number: 7)

        store.setGitHubBackfill([backfill])
        #expect(store.gitHubItems.count == 1)

        store.setItems([makeNotificationItem(id: "9001", number: 99)], for: .gitHub)

        #expect(store.gitHubItems.count == 2)
        #expect(store.gitHubItems.contains { $0.id == "gh:issue:owner/repo#7" })
        #expect(store.gitHubItems.contains { $0.id == "9001" })
    }

    @Test("A notification supersedes the backfilled copy of the same issue")
    @MainActor
    func testNotificationSupersedesBackfillForSameIssue() {
        let store = TriageStore()

        store.setGitHubBackfill([makeIssueItem(id: "gh:issue:owner/repo#7", number: 7)])
        store.setItems([makeNotificationItem(id: "9001", number: 7, title: "Unread update")], for: .gitHub)

        #expect(store.gitHubItems.count == 1)
        #expect(store.gitHubItems.first?.id == "9001")
        #expect(store.gitHubItems.first?.title == "Unread update")
    }

    @Test("Dismissing backfilled work is local-only and survives the next backfill")
    @MainActor
    func testDismissBackfillIsLocalAndTombstoned() {
        let store = TriageStore()
        store.githubService = nil

        let item = makeIssueItem(id: "gh:issue:owner/repo#7", number: 7)
        let sibling = makeIssueItem(id: "gh:issue:owner/repo#8", number: 8)
        store.setGitHubBackfill([item, sibling])

        store.archive(item: item)

        #expect(store.gitHubItems.count == 1)
        #expect(store.gitHubItems.first?.id == "gh:issue:owner/repo#8")
        #expect(store.toastMessage == nil)

        // The next backfill must not resurrect the dismissed issue.
        store.setGitHubBackfill([item, sibling])
        #expect(store.gitHubItems.count == 1)
        #expect(!store.gitHubItems.contains { $0.id == "gh:issue:owner/repo#7" })
    }

    @Test("Starring backfilled work persists across a backfill refresh")
    @MainActor
    func testStarredBackfillSurvivesRefresh() {
        let store = TriageStore()
        let item = makeIssueItem(id: "gh:issue:owner/repo#7", number: 7)

        store.setGitHubBackfill([item])
        store.star(item: store.gitHubItems[0])

        #expect(store.gitHubItems.first?.isStarred == true)

        store.setGitHubBackfill([item])
        #expect(store.gitHubItems.first?.isStarred == true)
    }

    @Test("Dismissed GitHub keys round-trip through the snapshot")
    @MainActor
    func testDismissedKeysPersistInSnapshot() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let snapshotURL = appSupport
            .appendingPathComponent("Dispatch", isDirectory: true)
            .appendingPathComponent("snapshot.json")
        let backup = try? Data(contentsOf: snapshotURL)
        defer {
            if let backup {
                try? backup.write(to: snapshotURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }

        let store = TriageStore()
        store.setGitHubBackfill([makeIssueItem(id: "gh:issue:owner/repo#7", number: 7)])
        store.archive(item: store.gitHubItems[0])
        store.saveSnapshotSync()

        let restored = TriageStore()
        restored.loadSnapshot()
        restored.setGitHubBackfill([makeIssueItem(id: "gh:issue:owner/repo#7", number: 7)])

        #expect(restored.gitHubItems.isEmpty)
    }
}
