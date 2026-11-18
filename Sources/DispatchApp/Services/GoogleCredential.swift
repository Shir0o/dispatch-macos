import Foundation

// MARK: - CredentialAvailability

/// Whether a Keychain credential exists and whether this build can read it.
///
/// macOS binds a generic-password item to the code signature that created it.
/// An ad-hoc signed build has a designated requirement made of its `cdhash`,
/// which changes on every build, so a downloaded update can find the item but
/// not read it. That failure is `inaccessible`, and it must not be reported as
/// "not configured": the user has a token, it just belongs to an older build.
public enum CredentialAvailability: Sendable, Equatable {
    case missing
    case available
    case inaccessible(message: String)

    /// True only when a credential is present and readable.
    public var isUsable: Bool {
        self == .available
    }
}

// MARK: - GoogleCredential

/// The Google token set stored in the Keychain.
public struct GoogleCredential: Sendable, Equatable {
    public var accessToken: String?
    public var refreshToken: String?
    public var expiry: Date?

    public init(accessToken: String?, refreshToken: String?, expiry: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }

    /// True when an access token exists and will still be valid after `leeway`.
    ///
    /// An access token with no recorded expiry is treated as unusable so the
    /// provider refreshes instead of sending a token that was minted in a
    /// previous session.
    public func hasUsableAccessToken(now: Date, leeway: TimeInterval = 60) -> Bool {
        guard accessToken?.isEmpty == false, let expiry else { return false }
        return expiry.timeIntervalSince(now) > leeway
    }
}

// MARK: - GoogleTokenError

public enum GoogleTokenError: LocalizedError, Sendable, Equatable {
    case notSignedIn
    case missingClientId
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Gmail isn't signed in. Add your Google Client ID and sign in from Settings."
        case .missingClientId:
            return "Add your Google Client ID in Settings, then sign in again."
        case .refreshFailed(let message):
            return "Gmail sign-in expired and could not be renewed: \(message)"
        }
    }
}
