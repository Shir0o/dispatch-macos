import Foundation

public enum TriageSource: String, Codable, Sendable, Hashable {
    case gmail
    case gitHub
}

public enum ReviewStatus: String, Codable, Sendable, Hashable {
    case pending
    case approved
    case changesRequested
    case none
}

public enum CheckSuiteStatus: String, Codable, Sendable, Hashable {
    case queued
    case inProgress
    case completedSuccess
    case completedFailure
    case neutral
}

public enum TriageKind: Codable, Sendable, Hashable {
    case email(threadId: String, snippet: String, hasHtml: Bool)
    case gitHubIssue(number: Int, repo: String, state: String, isAssignedToMe: Bool)
    case gitHubPullRequest(number: Int, repo: String, isDraft: Bool, reviewStatus: ReviewStatus, ciStatus: CheckSuiteStatus)
    case gitHubNotification(threadId: String, reason: String)
}

public struct TriageItem: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let source: TriageSource
    public let title: String
    public let authorName: String
    public let authorAvatarURL: URL?
    public let timestamp: Date
    public var isUnread: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public let tags: [String]
    public let kind: TriageKind
    public let webURL: URL

    public init(
        id: String,
        source: TriageSource,
        title: String,
        authorName: String,
        authorAvatarURL: URL? = nil,
        timestamp: Date,
        isUnread: Bool = true,
        isStarred: Bool = false,
        isArchived: Bool = false,
        tags: [String] = [],
        kind: TriageKind,
        webURL: URL
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.timestamp = timestamp
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.tags = tags
        self.kind = kind
        self.webURL = webURL
    }
}

extension TriageItem {
    /// Stable identity of the underlying GitHub issue/PR or mail thread.
    ///
    /// Notification items are keyed by GitHub's notification thread ID, while
    /// backfilled items are keyed by repository and number. Both resolve to the
    /// same canonical key when they refer to the same issue or pull request, so
    /// the two feeds can be merged without creating duplicates.
    public var canonicalKey: String {
        switch kind {
        case .email(let threadId, _, _):
            return "gmail:\(threadId)"
        case .gitHubIssue(let number, let repo, _, _):
            return "gh:\(repo)#\(number)"
        case .gitHubPullRequest(let number, let repo, _, _, _):
            return "gh:\(repo)#\(number)"
        case .gitHubNotification(let threadId, _):
            return "gh:thread:\(threadId)"
        }
    }

    /// `true` for items synthesised from the open issue/pull request backfill.
    ///
    /// These have no GitHub notification thread ID, so dismissing them must stay
    /// local instead of calling the notification endpoints.
    public var isBackfillDerived: Bool {
        source == .gitHub && id.hasPrefix("gh:")
    }
}

public struct GitHubIssueDetail: Codable, Sendable, Hashable {
    public let repo: String
    public let number: Int
    public let title: String
    public let body: String
    public let author: String
    public let createdAt: Date
    public let comments: [GitHubComment]

    public init(
        repo: String,
        number: Int,
        title: String,
        body: String,
        author: String,
        createdAt: Date,
        comments: [GitHubComment] = []
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.body = body
        self.author = author
        self.createdAt = createdAt
        self.comments = comments
    }
}

public struct GitHubComment: Codable, Sendable, Hashable {
    public let id: Int
    public let author: String
    public let body: String
    public let createdAt: Date

    public init(
        id: Int,
        author: String,
        body: String,
        createdAt: Date
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

public enum TerminalApp: String, Codable, Sendable, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm2 = "iTerm2"
    case ghostty = "Ghostty"
    case vscode = "Visual Studio Code"
    case alacritty = "Alacritty"

    public var id: String { rawValue }

    public var bundleIdentifier: String {
        switch self {
        case .terminal:
            return "com.apple.Terminal"
        case .iterm2:
            return "com.googlecode.iterm2"
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .vscode:
            return "com.microsoft.VSCode"
        case .alacritty:
            return "org.alacritty"
        }
    }
}

/// Local CLI coding agent that receives a dispatched issue prompt.
public enum AgentCLI: String, Codable, Sendable, CaseIterable, Identifiable {
    case opencode = "OpenCode"
    case claude = "Claude Code"
    case antigravity = "Antigravity"
    case custom = "Custom"
    case none = "Clipboard Only"

    public var id: String { rawValue }

    /// Executable and sub-command used to run the agent with a single message argument.
    public var defaultCommand: String {
        switch self {
        case .opencode:
            return "opencode run"
        case .claude:
            return "claude"
        case .antigravity:
            return "antigravity"
        case .custom, .none:
            return ""
        }
    }

    public var requiresCommand: Bool {
        self == .custom
    }
}

public struct AgentDispatchPayload: Sendable, Hashable {
    public let issueNumber: Int
    public let repository: String
    public let title: String
    public let body: String
    public let comments: [GitHubComment]
    public let localRepoPath: URL?

    public init(
        issueNumber: Int,
        repository: String,
        title: String,
        body: String,
        comments: [GitHubComment] = [],
        localRepoPath: URL? = nil
    ) {
        self.issueNumber = issueNumber
        self.repository = repository
        self.title = title
        self.body = body
        self.comments = comments
        self.localRepoPath = localRepoPath
    }

    public var formattedPrompt: String {
        let commentsText = comments.isEmpty
            ? "No comments."
            : comments.map { "### @\($0.author) on \($0.createdAt):\n\($0.body)" }.joined(separator: "\n\n---\n\n")

        let pathLine = localRepoPath != nil ? "Local Path: \(localRepoPath!.path)\n" : ""

        return """
        # Task: Address GitHub Issue #\(issueNumber) in \(repository)
        Title: \(title)
        \(pathLine)
        ## Description
        \(body)

        ## Comments
        \(commentsText)
        """
    }
}
