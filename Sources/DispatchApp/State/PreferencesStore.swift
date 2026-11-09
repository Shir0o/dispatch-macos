import Foundation
import Observation

/// Manages user preferences backed by `UserDefaults`.
@Observable
@MainActor
public final class PreferencesStore {
    private enum Keys {
        static let googleClientId = "dispatch.googleClientId"
        static let githubPAT = "dispatch.githubPAT"
        static let githubUsername = "dispatch.githubUsername"
        static let trackedRepositories = "dispatch.trackedRepositories"
        static let projectsDirectory = "dispatch.projectsDirectory"
        static let preferredTerminal = "dispatch.preferredTerminal"
    }

    private let defaults: UserDefaults

    /// Configured Google OAuth Client ID.
    public var googleClientId: String {
        didSet {
            defaults.set(googleClientId, forKey: Keys.googleClientId)
        }
    }

    /// GitHub Personal Access Token (stored locally or synchronized with Keychain).
    public var githubPAT: String {
        didSet {
            defaults.set(githubPAT, forKey: Keys.githubPAT)
        }
    }

    /// Login of the authenticated GitHub user, captured when a PAT is validated.
    public var githubUsername: String {
        didSet {
            defaults.set(githubUsername, forKey: Keys.githubUsername)
        }
    }

    /// `owner/repo` entries whose open issues and pull requests are backfilled.
    /// An empty list means "everything the authenticated user is involved with".
    public var trackedRepositories: [String] {
        didSet {
            defaults.set(trackedRepositories, forKey: Keys.trackedRepositories)
        }
    }

    /// Default directory for local software projects (defaults to `~/Projects`).
    public var projectsDirectory: String {
        didSet {
            defaults.set(projectsDirectory, forKey: Keys.projectsDirectory)
        }
    }

    /// User's preferred terminal application for agent dispatch.
    public var preferredTerminal: TerminalApp {
        didSet {
            defaults.set(preferredTerminal.rawValue, forKey: Keys.preferredTerminal)
        }
    }

    /// Initializes preferences from the given `UserDefaults` instance.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.googleClientId = defaults.string(forKey: Keys.googleClientId) ?? ""
        self.githubPAT = defaults.string(forKey: Keys.githubPAT) ?? ""
        self.githubUsername = defaults.string(forKey: Keys.githubUsername) ?? ""
        self.trackedRepositories = defaults.stringArray(forKey: Keys.trackedRepositories) ?? []
        self.projectsDirectory = defaults.string(forKey: Keys.projectsDirectory) ?? "~/Projects"

        if let termRaw = defaults.string(forKey: Keys.preferredTerminal),
           let term = TerminalApp(rawValue: termRaw) {
            self.preferredTerminal = term
        } else {
            self.preferredTerminal = .terminal
        }
    }

    /// Tracked repositories, normalized to well-formed, de-duplicated `owner/repo` entries.
    public var normalizedTrackedRepositories: [String] {
        GitHubService.normalizeRepositories(trackedRepositories)
    }

    /// Resolves local repository path given a repository name (e.g. "repo-name" or "owner/repo-name").
    ///
    /// Searches `projectsDirectory` for matching directories.
    public func localPath(for repoName: String) -> URL? {
        let trimmedDir = projectsDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDir = trimmedDir.isEmpty ? "~/Projects" : trimmedDir
        let expanded = NSString(string: effectiveDir).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }

        let baseURL = URL(fileURLWithPath: expanded, isDirectory: true)
        let trimmedRepo = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty else { return baseURL }

        let simpleName = trimmedRepo.split(separator: "/").last.map(String.init) ?? trimmedRepo

        let candidateSimple = baseURL.appendingPathComponent(simpleName, isDirectory: true)
        let candidateFull = baseURL.appendingPathComponent(trimmedRepo, isDirectory: true)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: candidateSimple.path) {
            return candidateSimple
        }
        if fileManager.fileExists(atPath: candidateFull.path) {
            return candidateFull
        }

        return candidateSimple
    }
}

extension Notification.Name {
    /// Posted when the user asks to re-run the open issue / pull request backfill.
    static let dispatchGitHubBackfillRequested = Notification.Name("dispatch.githubBackfillRequested")
}
