import Foundation

// MARK: - OpenWorkItemKind

/// The kind of GitHub work an `OpenWorkItem` represents.
public enum OpenWorkItemKind: Hashable, Sendable {
    case issue
    case pullRequest
}

// MARK: - OpenWorkItem

/// One open issue or pull request that involves the authenticated user.
///
/// Kept separate from `TriageItem`: imported work is not triage mail, and
/// `TriageItem` is persisted in the Gmail snapshot.
public struct OpenWorkItem: Identifiable, Hashable, Sendable {
    /// `owner/repo#number`, lowercased, stable within a repository.
    public let key: String
    /// `owner/repo`, preserving display case.
    public let repository: String
    public let number: Int
    public let kind: OpenWorkItemKind
    public let title: String
    public let authorLogin: String
    public let updatedAt: Date
    public let webURL: URL

    public var id: String { key }

    public init(
        key: String,
        repository: String,
        number: Int,
        kind: OpenWorkItemKind,
        title: String,
        authorLogin: String,
        updatedAt: Date,
        webURL: URL
    ) {
        self.key = key
        self.repository = repository
        self.number = number
        self.kind = kind
        self.title = title
        self.authorLogin = authorLogin
        self.updatedAt = updatedAt
        self.webURL = webURL
    }
}

// MARK: - OpenWorkGroup

/// A repository section in the Open Work list.
public struct OpenWorkGroup: Hashable, Sendable {
    public let repository: String
    public let items: [OpenWorkItem]
    public let visibleCount: Int

    public init(repository: String, items: [OpenWorkItem], visibleCount: Int) {
        self.repository = repository
        self.items = items
        self.visibleCount = visibleCount
    }
}

// MARK: - OpenWorkFetchResult

/// The payload of one successful Open Work fetch.
public struct OpenWorkFetchResult: Hashable, Sendable {
    public let items: [OpenWorkItem]
    /// GitHub's `total_count`, capped by GitHub at 1,000.
    public let matchedCount: Int
    /// Unique items returned, after deduplication.
    public let fetchedCount: Int
    public let truncated: Bool
    /// True when the run is not truncated and pagination ended with no next link.
    public let complete: Bool

    public init(
        items: [OpenWorkItem],
        matchedCount: Int,
        fetchedCount: Int,
        truncated: Bool,
        complete: Bool
    ) {
        self.items = items
        self.matchedCount = matchedCount
        self.fetchedCount = fetchedCount
        self.truncated = truncated
        self.complete = complete
    }
}

// MARK: - OpenWorkFetchError

/// The error surface the Open Work view maps to an action.
public enum OpenWorkFetchError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case forbidden(resetAt: Date?)
    case notFound
    case server(status: Int)
    case decoding
    case transport

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "GitHub isn't connected. Add a personal access token in Settings."
        case .unauthorized:
            return "GitHub rejected the token. Update it in Settings."
        case .forbidden(let resetAt):
            if let resetAt {
                return "GitHub rate limit reached. Retry after \(resetAt.formatted(date: .omitted, time: .shortened))."
            }
            return "GitHub refused the request (HTTP 403)."
        case .notFound:
            return "Open Work endpoint not found."
        case .server(let status):
            return "GitHub server error (HTTP \(status))."
        case .decoding:
            return "GitHub returned an unexpected response."
        case .transport:
            return "Network unavailable. Check your connection and try again."
        }
    }
}

// MARK: - OpenWorkStatus

/// The refresh state the Open Work header reads.
public enum OpenWorkPhase: Hashable, Sendable {
    case idle
    case running
    case ready
}

public struct OpenWorkStatus: Sendable {
    public var phase: OpenWorkPhase
    public var lastSuccess: Date?
    public var matchedCount: Int
    public var fetchedCount: Int
    public var truncated: Bool
    public var updatedCount: Int
    public var error: OpenWorkFetchError?

    public init(
        phase: OpenWorkPhase = .idle,
        lastSuccess: Date? = nil,
        matchedCount: Int = 0,
        fetchedCount: Int = 0,
        truncated: Bool = false,
        updatedCount: Int = 0,
        error: OpenWorkFetchError? = nil
    ) {
        self.phase = phase
        self.lastSuccess = lastSuccess
        self.matchedCount = matchedCount
        self.fetchedCount = fetchedCount
        self.truncated = truncated
        self.updatedCount = updatedCount
        self.error = error
    }
}

// MARK: - OpenWorkLastRunSummary

/// The persisted summary of the last successful run, for display on cold start.
public struct OpenWorkLastRunSummary: Codable, Sendable {
    public let lastSuccess: Date?
    public let matchedCount: Int
    public let fetchedCount: Int
    public let truncated: Bool

    public init(
        lastSuccess: Date?,
        matchedCount: Int,
        fetchedCount: Int,
        truncated: Bool
    ) {
        self.lastSuccess = lastSuccess
        self.matchedCount = matchedCount
        self.fetchedCount = fetchedCount
        self.truncated = truncated
    }
}
