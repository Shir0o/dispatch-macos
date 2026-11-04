import Foundation

// MARK: - GitHubError

public enum GitHubError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case forbidden(rateLimitReset: Date?)
    case notFound(String)
    case invalidResponse(statusCode: Int, message: String)
    case decodingError(String)
    case missingToken
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "GitHub Personal Access Token is invalid or expired (HTTP 401)."
        case .forbidden(let resetDate):
            if let resetDate = resetDate {
                return "GitHub API rate limit exceeded. Reset at \(resetDate)."
            }
            return "GitHub API access forbidden or rate limit exceeded (HTTP 403)."
        case .notFound(let resource):
            return "GitHub resource not found: \(resource) (HTTP 404)."
        case .invalidResponse(let statusCode, let message):
            return "GitHub API HTTP \(statusCode): \(message)"
        case .decodingError(let message):
            return "GitHub response decoding failed: \(message)"
        case .missingToken:
            return "No GitHub Personal Access Token configured in Keychain."
        case .invalidURL:
            return "Failed to construct GitHub API URL."
        }
    }
}

// MARK: - GitHubService

public final class GitHubService: Sendable {
    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let baseURL = "https://api.github.com"

    public init(
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public convenience init(authService: AuthService, session: URLSession = .shared) {
        self.init(session: session) {
            guard let token = try await authService.readKeychainValue(key: AuthService.gitHubPATKey) else {
                throw GitHubError.missingToken
            }
            return token
        }
    }

    // MARK: - HTTP Helpers

    private func makeRequest(
        endpoint: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let urlString = endpoint.hasPrefix("http") ? endpoint : "\(baseURL)/\(endpoint)"
        guard let url = URL(string: urlString) else {
            throw GitHubError.invalidURL
        }

        let token = try await tokenProvider()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Dispatch-macOS", forHTTPHeaderField: "User-Agent")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse(statusCode: 0, message: "Invalid HTTP response")
        }

        return (data, httpResponse)
    }

    // MARK: - Notifications

    public func fetchNotifications(
        lastETag: String?
    ) async throws -> (items: [TriageItem], newETag: String?, notModified: Bool) {
        var headers: [String: String] = [:]
        if let etag = lastETag, !etag.isEmpty {
            headers["If-None-Match"] = etag
        }

        let (data, response) = try await makeRequest(
            endpoint: "notifications?all=false",
            headers: headers
        )

        if response.statusCode == 304 {
            return (items: [], newETag: lastETag, notModified: true)
        }

        if response.statusCode == 401 {
            throw GitHubError.unauthorized
        }

        if response.statusCode == 403 {
            var resetDate: Date?
            if let resetHeader = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
               let epoch = Double(resetHeader) {
                resetDate = Date(timeIntervalSince1970: epoch)
            }
            throw GitHubError.forbidden(rateLimitReset: resetDate)
        }

        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GitHubError.invalidResponse(statusCode: response.statusCode, message: msg)
        }

        let rawETag = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "etag")

        struct RepoOwner: Decodable {
            let login: String
            let avatar_url: String
        }

        struct RepoInfo: Decodable {
            let id: Int
            let name: String
            let full_name: String
            let html_url: String
            let owner: RepoOwner
        }

        struct NotificationSubject: Decodable {
            let title: String
            let url: String?
            let latest_comment_url: String?
            let type: String
        }

        struct NotificationItem: Decodable {
            let id: String
            let unread: Bool
            let reason: String
            let updated_at: String
            let subject: NotificationSubject
            let repository: RepoInfo
            let url: String
        }

        let notificationList: [NotificationItem]
        do {
            notificationList = try JSONDecoder().decode([NotificationItem].self, from: data)
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIsoFormatter = ISO8601DateFormatter()

        let items: [TriageItem] = notificationList.map { notif in
            let date = isoFormatter.date(from: notif.updated_at)
                ?? fallbackIsoFormatter.date(from: notif.updated_at)
                ?? Date()

            let subjectNumber: Int = {
                if let urlString = notif.subject.url,
                   let last = urlString.split(separator: "/").last,
                   let num = Int(last) {
                    return num
                }
                return 0
            }()

            let typeLower = notif.subject.type.lowercased()
            let kind: TriageKind
            let webURL: URL

            if typeLower == "issue" {
                let isAssigned = notif.reason == "assign" || notif.reason == "author"
                kind = .gitHubIssue(
                    number: subjectNumber,
                    repo: notif.repository.full_name,
                    state: "open",
                    isAssignedToMe: isAssigned
                )
                webURL = URL(string: "\(notif.repository.html_url)/issues/\(subjectNumber)")
                    ?? URL(string: notif.repository.html_url)!
            } else if typeLower == "pullrequest" {
                let reviewStatus: ReviewStatus = notif.reason == "review_requested" ? .pending : .none
                let ciStatus: CheckSuiteStatus = notif.reason == "ci_activity" ? .queued : .neutral
                kind = .gitHubPullRequest(
                    number: subjectNumber,
                    repo: notif.repository.full_name,
                    isDraft: false,
                    reviewStatus: reviewStatus,
                    ciStatus: ciStatus
                )
                webURL = URL(string: "\(notif.repository.html_url)/pull/\(subjectNumber)")
                    ?? URL(string: notif.repository.html_url)!
            } else {
                kind = .gitHubNotification(threadId: notif.id, reason: notif.reason)
                webURL = URL(string: notif.repository.html_url)
                    ?? URL(string: "https://github.com/notifications")!
            }

            let avatarURL = URL(string: notif.repository.owner.avatar_url)

            return TriageItem(
                id: notif.id,
                source: .gitHub,
                title: notif.subject.title,
                authorName: notif.repository.full_name,
                authorAvatarURL: avatarURL,
                timestamp: date,
                isUnread: notif.unread,
                isStarred: false,
                isArchived: false,
                tags: [notif.reason, notif.subject.type],
                kind: kind,
                webURL: webURL
            )
        }

        return (items: items, newETag: rawETag, notModified: false)
    }

    // MARK: - Check Runs

    public func fetchCheckRuns(
        owner: String,
        repo: String,
        ref: String
    ) async throws -> CheckSuiteStatus {
        let endpoint = "repos/\(owner)/\(repo)/commits/\(ref)/check-runs"
        let (data, response) = try await makeRequest(endpoint: endpoint)

        if response.statusCode == 401 { throw GitHubError.unauthorized }
        if response.statusCode == 404 { return .neutral }

        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GitHubError.invalidResponse(statusCode: response.statusCode, message: msg)
        }

        struct CheckRunItem: Decodable {
            let id: Int
            let status: String
            let conclusion: String?
        }

        struct CheckRunsResponse: Decodable {
            let total_count: Int
            let check_runs: [CheckRunItem]
        }

        let checkRunsResult: CheckRunsResponse
        do {
            checkRunsResult = try JSONDecoder().decode(CheckRunsResponse.self, from: data)
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }

        let runs = checkRunsResult.check_runs
        guard !runs.isEmpty else { return .neutral }

        let hasFailure = runs.contains { run in
            if let conclusion = run.conclusion?.lowercased() {
                return conclusion == "failure"
                    || conclusion == "timed_out"
                    || conclusion == "action_required"
                    || conclusion == "cancelled"
            }
            return false
        }
        if hasFailure {
            return .completedFailure
        }

        let hasInProgress = runs.contains { $0.status.lowercased() == "in_progress" }
        if hasInProgress {
            return .inProgress
        }

        let hasQueued = runs.contains { $0.status.lowercased() == "queued" }
        if hasQueued {
            return .queued
        }

        let allCompleted = runs.allSatisfy { $0.status.lowercased() == "completed" }
        if allCompleted {
            let allSuccess = runs.allSatisfy { run in
                guard let c = run.conclusion?.lowercased() else { return false }
                return c == "success" || c == "neutral" || c == "skipped"
            }
            if allSuccess {
                return .completedSuccess
            }
        }

        return .neutral
    }

    // MARK: - Issue & Comments Details

    public func fetchIssueDetails(repo: String, number: Int) async throws -> GitHubIssueDetail {
        async let issueCall = makeRequest(endpoint: "repos/\(repo)/issues/\(number)")
        async let commentsCall = makeRequest(endpoint: "repos/\(repo)/issues/\(number)/comments?per_page=100")

        let ((issueData, issueResponse), (commentsData, commentsResponse)) = try await (issueCall, commentsCall)

        if issueResponse.statusCode == 401 || commentsResponse.statusCode == 401 {
            throw GitHubError.unauthorized
        }
        if issueResponse.statusCode == 404 {
            throw GitHubError.notFound("Issue #\(number) in \(repo)")
        }

        guard (200...299).contains(issueResponse.statusCode) else {
            let msg = String(data: issueData, encoding: .utf8) ?? "HTTP \(issueResponse.statusCode)"
            throw GitHubError.invalidResponse(statusCode: issueResponse.statusCode, message: msg)
        }

        struct IssueAuthor: Decodable {
            let login: String
        }

        struct IssuePayload: Decodable {
            let number: Int
            let title: String
            let body: String?
            let user: IssueAuthor?
            let created_at: String
        }

        let issue: IssuePayload
        do {
            issue = try JSONDecoder().decode(IssuePayload.self, from: issueData)
        } catch {
            throw GitHubError.decodingError("Issue parsing: \(error.localizedDescription)")
        }

        struct CommentPayload: Decodable {
            let id: Int
            let user: IssueAuthor?
            let body: String?
            let created_at: String
        }

        var commentsList: [CommentPayload] = []
        if (200...299).contains(commentsResponse.statusCode) {
            commentsList = (try? JSONDecoder().decode([CommentPayload].self, from: commentsData)) ?? []
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIsoFormatter = ISO8601DateFormatter()

        let issueDate = isoFormatter.date(from: issue.created_at)
            ?? fallbackIsoFormatter.date(from: issue.created_at)
            ?? Date()

        let comments: [GitHubComment] = commentsList.map { c in
            let date = isoFormatter.date(from: c.created_at)
                ?? fallbackIsoFormatter.date(from: c.created_at)
                ?? Date()
            return GitHubComment(
                id: c.id,
                author: c.user?.login ?? "ghost",
                body: c.body ?? "",
                createdAt: date
            )
        }

        return GitHubIssueDetail(
            repo: repo,
            number: issue.number,
            title: issue.title,
            body: issue.body ?? "",
            author: issue.user?.login ?? "ghost",
            createdAt: issueDate,
            comments: comments
        )
    }

    // MARK: - Notification Dismissal & Unsubscribe

    public func dismissNotification(threadId: String) async throws {
        let (data, response) = try await makeRequest(
            endpoint: "notifications/threads/\(threadId)",
            method: "PATCH"
        )

        if response.statusCode == 401 { throw GitHubError.unauthorized }

        // GitHub returns HTTP 205 (Reset Content), 200, or 204
        guard [200, 204, 205].contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GitHubError.invalidResponse(statusCode: response.statusCode, message: msg)
        }
    }

    public func unsubscribeNotification(threadId: String) async throws {
        let (data, response) = try await makeRequest(
            endpoint: "notifications/threads/\(threadId)/subscription",
            method: "DELETE"
        )

        if response.statusCode == 401 { throw GitHubError.unauthorized }

        guard [200, 204].contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GitHubError.invalidResponse(statusCode: response.statusCode, message: msg)
        }

        // Also mark as read locally and on server
        _ = try? await dismissNotification(threadId: threadId)
    }
}
