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

    // MARK: - Open Work

    /// Fetches every open issue and pull request that involves the authenticated
    /// user, using one search query with its own pagination.
    ///
    /// Pages are followed through the `Link: rel="next"` header, up to four
    /// pages (400 items). Any non-2xx response on any page throws; a 404 is not
    /// an empty success. Duplicates across pages are dropped, keeping the first
    /// occurrence in page order.
    public func fetchOpenWork() async throws -> OpenWorkFetchResult {
        let maxPages = 4
        let maxItems = 400

        guard var components = URLComponents(string: "\(baseURL)/search/issues") else {
            throw OpenWorkFetchError.transport
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: "is:open involves:@me"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "100")
        ]
        guard let firstPageURL = components.url else {
            throw OpenWorkFetchError.transport
        }

        do {
            var nextPage: String? = firstPageURL.absoluteString
            var pageIndex = 0
            var matchedCount = 0
            var items: [OpenWorkItem] = []
            var seenKeys = Set<String>()

            while let currentPage = nextPage, pageIndex < maxPages {
                let (data, response) = try await makeRequest(endpoint: currentPage)
                try Self.validate(response: response, data: data, context: "open work search")

                let page: OpenWorkSearchResponse
                do {
                    page = try JSONDecoder().decode(OpenWorkSearchResponse.self, from: data)
                } catch {
                    throw OpenWorkFetchError.decoding
                }

                if pageIndex == 0 {
                    matchedCount = page.total_count
                }

                for payload in page.items {
                    guard let item = Self.mapOpenWorkItem(payload) else { continue }
                    if seenKeys.insert(item.key).inserted {
                        items.append(item)
                    }
                }

                nextPage = Self.nextPageURL(from: response)
                pageIndex += 1
            }

            // Page four advertising a next link means GitHub has more work than
            // the 400-item cap can show.
            let hasMoreAfterCap = pageIndex >= maxPages && nextPage != nil
            let truncated = matchedCount > maxItems || hasMoreAfterCap
            let complete = !truncated && nextPage == nil

            return OpenWorkFetchResult(
                items: items,
                matchedCount: matchedCount,
                fetchedCount: items.count,
                truncated: truncated,
                complete: complete
            )
        } catch let error as OpenWorkFetchError {
            throw error
        } catch {
            throw Self.openWorkError(from: error)
        }
    }

    /// Maps the underlying GitHub, auth and URL errors onto the Open Work error
    /// surface. The store never sees `GitHubError` or `AuthError`.
    private static func openWorkError(from error: Error) -> OpenWorkFetchError {
        if let openWorkError = error as? OpenWorkFetchError {
            return openWorkError
        }

        if let gitHubError = error as? GitHubError {
            switch gitHubError {
            case .missingToken:
                return .notConfigured
            case .unauthorized:
                return .unauthorized
            case .forbidden(let resetAt):
                return .forbidden(resetAt: resetAt)
            case .notFound:
                return .notFound
            case .invalidResponse(let statusCode, _):
                return .server(status: statusCode)
            case .decodingError:
                return .decoding
            case .invalidURL:
                return .transport
            }
        }

        if let authError = error as? AuthError {
            switch authError {
            case .keychainError, .decodingFailed:
                return .notConfigured
            default:
                return .transport
            }
        }

        if error is URLError {
            return .transport
        }

        return .transport
    }

    // MARK: - HTTP Validation Helpers

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
    struct OpenWorkUserPayload: Decodable {
        let login: String
        let avatar_url: String?
    }

    struct OpenWorkLabelPayload: Decodable {
        let name: String
    }

    struct OpenWorkPullRequestReference: Decodable {
        let url: String?
    }

    struct OpenWorkIssuePayload: Decodable {
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

    struct OpenWorkSearchResponse: Decodable {
        let total_count: Int
        let items: [OpenWorkIssuePayload]
    }

    /// Maps one search record to an `OpenWorkItem`.
    ///
    /// Records with an unparsable `repository_url` or `html_url` are skipped.
    /// A missing author becomes `"ghost"`; an unparsable `updated_at` falls back
    /// to `Date()`.
    static func mapOpenWorkItem(_ payload: OpenWorkIssuePayload) -> OpenWorkItem? {
        guard let repository = repositoryName(from: payload.repository_url),
              let webURL = URL(string: payload.html_url) else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        let updatedAt = fractionalFormatter.date(from: payload.updated_at)
            ?? plainFormatter.date(from: payload.updated_at)
            ?? Date()

        return OpenWorkItem(
            key: "\(repository.lowercased())#\(payload.number)",
            repository: repository,
            number: payload.number,
            kind: payload.pull_request != nil ? .pullRequest : .issue,
            title: payload.title,
            authorLogin: payload.user?.login ?? "ghost",
            updatedAt: updatedAt,
            webURL: webURL
        )
    }

    private static func repositoryName(from repositoryURL: String) -> String? {
        let parts = repositoryURL.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
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
}
