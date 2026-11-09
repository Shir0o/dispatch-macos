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

    // MARK: - Open Work Backfill

    /// Fetches every open issue and pull request for the supplied repositories
    /// and/or repository owners.
    ///
    /// Unlike `/notifications` (which only returns unread threads), this is used
    /// once at launch to seed the workspace with work that already existed
    /// before Dispatch was installed.
    ///
    /// - Parameters:
    ///   - repositories: `owner/repo` entries to scan.
    ///   - owners: GitHub users or organizations. Every open issue and pull
    ///     request across all repositories they own is included, so the user
    ///     can track an entire account instead of pasting each repository.
    ///   - login: Authenticated user's login, used to flag items assigned to them.
    ///   - maxPagesPerSource: Page cap per repository or owner search.
    ///
    /// When both `repositories` and `owners` are empty, falls back to
    /// `/issues?filter=all`, i.e. every open issue and pull request the
    /// authenticated user is involved with.
    public func fetchOpenIssuesAndPullRequests(
        repositories: [String] = [],
        owners: [String] = [],
        login: String? = nil,
        maxPagesPerSource: Int = 3
    ) async throws -> [TriageItem] {
        let normalizedRepositories = Self.normalizeRepositories(repositories)
        let normalizedOwners = Self.normalizeOwners(owners)

        if normalizedRepositories.isEmpty && normalizedOwners.isEmpty {
            let pages = try await requestAllPages(
                endpoint: "issues?filter=all&state=open&sort=updated&per_page=100",
                context: "open issues",
                maxPages: maxPagesPerSource
            )
            return try Self.decodeOpenWork(pages: pages, login: login)
        }

        return await withTaskGroup(of: [TriageItem].self) { group in
            for repo in normalizedRepositories {
                group.addTask {
                    // One unreachable repository must not blank the whole
                    // backfill, so each source fails independently.
                    guard let pages = try? await self.requestAllPages(
                        endpoint: "repos/\(repo)/issues?state=open&sort=updated&per_page=100",
                        context: "open issues for \(repo)",
                        maxPages: maxPagesPerSource
                    ), let items = try? Self.decodeOpenWork(pages: pages, login: login) else {
                        return []
                    }
                    return items
                }
            }

            for owner in normalizedOwners {
                group.addTask {
                    // The search API's `user:` qualifier matches repositories
                    // owned by a user or organization, so one query covers an
                    // entire account without enumerating its repositories.
                    let query = "is:open+user:\(owner)"
                    guard let pages = try? await self.requestAllPages(
                        endpoint: "search/issues?q=\(query)&sort=updated&order=desc&per_page=100",
                        context: "open issues for \(owner)",
                        maxPages: maxPagesPerSource
                    ), let items = try? Self.decodeSearchOpenWork(pages: pages, login: login) else {
                        return []
                    }
                    return items
                }
            }

            var items: [TriageItem] = []
            for await batch in group {
                items.append(contentsOf: batch)
            }
            return Self.deduplicated(items)
        }
    }

    /// Normalizes user-provided `owner/repo` strings, dropping blanks and duplicates.
    public static func normalizeRepositories(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let repo = parts.joined(separator: "/")
            return seen.insert(repo.lowercased()).inserted ? repo : nil
        }
    }

    /// Normalizes user-provided GitHub usernames or organization names.
    ///
    /// Accepts a bare login, an `@login`, or a pasted profile URL, drops blanks,
    /// malformed entries and duplicates, and preserves the first spelling seen.
    public static func normalizeOwners(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { entry in
            var candidate = entry.trimmingCharacters(in: .whitespacesAndNewlines)

            if let hostRange = candidate.range(of: "github.com/") {
                // Accept a pasted profile URL, keeping only the account segment.
                candidate = String(candidate[hostRange.upperBound...])
                if let slash = candidate.firstIndex(of: "/") {
                    candidate = String(candidate[..<slash])
                }
            } else if candidate.contains("/") {
                // `owner/repo` belongs in the repository list, not here.
                return nil
            }

            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))

            guard !candidate.isEmpty,
                  candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                return nil
            }

            return seen.insert(candidate.lowercased()).inserted ? candidate : nil
        }
    }

    // MARK: - Backfill HTTP & Parsing Helpers

    private func requestAllPages(
        endpoint: String,
        context: String,
        maxPages: Int
    ) async throws -> [Data] {
        var pages: [Data] = []
        var next: String? = endpoint
        var pageCount = 0

        while let current = next, pageCount < maxPages {
            let (data, response) = try await makeRequest(endpoint: current)
            if response.statusCode == 404 {
                return pages
            }
            try Self.validate(response: response, data: data, context: context)
            pages.append(data)
            pageCount += 1
            next = Self.nextPageURL(from: response)
        }

        return pages
    }

    private static func validate(
        response: HTTPURLResponse,
        data: Data,
        context: String
    ) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            throw GitHubError.unauthorized
        case 403:
            var resetDate: Date?
            if let header = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
               let epoch = Double(header) {
                resetDate = Date(timeIntervalSince1970: epoch)
            }
            throw GitHubError.forbidden(rateLimitReset: resetDate)
        case 404:
            throw GitHubError.notFound(context)
        default:
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GitHubError.invalidResponse(statusCode: response.statusCode, message: message)
        }
    }

    private static func nextPageURL(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Link") else { return nil }

        for link in header.split(separator: ",") {
            let segments = link.split(separator: ";")
            guard segments.count > 1 else { continue }
            let hasNext = segments.dropFirst().contains { segment in
                segment.replacingOccurrences(of: " ", with: "").contains("rel=\"next\"")
            }
            guard hasNext else { continue }

            let target = segments[0].trimmingCharacters(in: .whitespaces)
            guard target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            return String(target.dropFirst().dropLast())
        }

        return nil
    }

    // Decoding shapes shared by the repository listing and the scoped search
    // endpoints. The search endpoint nests the same issue records under `items`.
    private struct OpenWorkUserPayload: Decodable {
        let login: String
        let avatar_url: String?
    }

    private struct OpenWorkLabelPayload: Decodable {
        let name: String
    }

    private struct OpenWorkPullRequestReference: Decodable {
        let url: String?
    }

    private struct OpenWorkIssuePayload: Decodable {
        let number: Int
        let title: String
        let state: String
        let draft: Bool?
        let user: OpenWorkUserPayload?
        let labels: [OpenWorkLabelPayload]?
        let assignees: [OpenWorkUserPayload]?
        let updated_at: String
        let html_url: String
        let repository_url: String
        let pull_request: OpenWorkPullRequestReference?
    }

    private struct OpenWorkSearchResponse: Decodable {
        let items: [OpenWorkIssuePayload]
    }

    private static func decodeOpenWork(
        pages: [Data],
        login: String?
    ) throws -> [TriageItem] {
        var issues: [OpenWorkIssuePayload] = []

        for page in pages {
            do {
                issues.append(contentsOf: try JSONDecoder().decode([OpenWorkIssuePayload].self, from: page))
            } catch {
                throw GitHubError.decodingError(error.localizedDescription)
            }
        }

        return mapOpenWork(issues: issues, login: login)
    }

    private static func decodeSearchOpenWork(
        pages: [Data],
        login: String?
    ) throws -> [TriageItem] {
        var issues: [OpenWorkIssuePayload] = []

        for page in pages {
            do {
                issues.append(
                    contentsOf: try JSONDecoder().decode(OpenWorkSearchResponse.self, from: page).items
                )
            } catch {
                throw GitHubError.decodingError(error.localizedDescription)
            }
        }

        return mapOpenWork(issues: issues, login: login)
    }

    private static func mapOpenWork(
        issues: [OpenWorkIssuePayload],
        login: String?
    ) -> [TriageItem] {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        var items: [TriageItem] = []

        for issue in issues {
            guard let repo = repositoryName(from: issue.repository_url),
                  let webURL = URL(string: issue.html_url) else { continue }

            let date = fractionalFormatter.date(from: issue.updated_at)
                ?? plainFormatter.date(from: issue.updated_at)
                ?? Date()

            let isPullRequest = issue.pull_request != nil
            let labels = issue.labels?.map(\.name) ?? []
            let isAssignedToMe: Bool = {
                guard let login, !login.isEmpty else { return false }
                return (issue.assignees ?? []).contains {
                    $0.login.caseInsensitiveCompare(login) == .orderedSame
                }
            }()

            let kind: TriageKind = isPullRequest
                ? .gitHubPullRequest(
                    number: issue.number,
                    repo: repo,
                    isDraft: issue.draft ?? false,
                    reviewStatus: .none,
                    ciStatus: .neutral
                )
                : .gitHubIssue(
                    number: issue.number,
                    repo: repo,
                    state: issue.state,
                    isAssignedToMe: isAssignedToMe
                )

            let idPrefix = isPullRequest ? "gh:pr:" : "gh:issue:"

            items.append(
                TriageItem(
                    id: "\(idPrefix)\(repo)#\(issue.number)",
                    source: .gitHub,
                    title: issue.title,
                    authorName: issue.user?.login ?? "ghost",
                    authorAvatarURL: issue.user?.avatar_url.flatMap { URL(string: $0) },
                    timestamp: date,
                    isUnread: false,
                    isStarred: false,
                    isArchived: false,
                    tags: labels,
                    kind: kind,
                    webURL: webURL
                )
            )
        }

        return items
    }

    private static func deduplicated(_ items: [TriageItem]) -> [TriageItem] {
        var seen = Set<String>()
        var unique: [TriageItem] = []
        for item in items where seen.insert(item.id).inserted {
            unique.append(item)
        }
        return unique.sorted(by: newestFirst)
    }

    private static func repositoryName(from repositoryURL: String) -> String? {
        let parts = repositoryURL.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    private static func newestFirst(_ lhs: TriageItem, _ rhs: TriageItem) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        return lhs.id < rhs.id
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
