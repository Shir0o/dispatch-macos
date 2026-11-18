import Foundation

// MARK: - GoogleTokenProvider

/// Supplies a valid Google access token, refreshing an expired one first.
///
/// Gmail access tokens live about an hour. Before this provider existed the app
/// sent whatever token was stored at sign-in, so every Gmail request failed with
/// HTTP 401 once that hour elapsed and the sync loop swallowed the error. The
/// provider reads the stored expiry, refreshes through `AuthService` when needed,
/// and serialises concurrent refreshes so a burst of parallel thread fetches
/// does not mint one token per request.
public actor GoogleTokenProvider {
    public typealias Reader = @Sendable () async throws -> GoogleCredential
    public typealias Refresher = @Sendable (_ refreshToken: String) async throws -> GoogleCredential

    private let read: Reader
    private let refresher: Refresher
    private let now: @Sendable () -> Date
    private let leeway: TimeInterval

    private var refreshTask: Task<GoogleCredential, any Error>?
    private var refreshGeneration = 0

    public init(
        leeway: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init,
        read: @escaping Reader,
        refresher: @escaping Refresher
    ) {
        self.leeway = leeway
        self.now = now
        self.read = read
        self.refresher = refresher
    }

    /// Returns a token that should be accepted by Google right now.
    ///
    /// - Parameter forceRefresh: Set after a 401 so a token that looked valid
    ///   (clock skew, revoked grant) is replaced instead of reused.
    public func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh {
            let credential = try await currentCredential()
            if credential.hasUsableAccessToken(now: now(), leeway: leeway),
               let accessToken = credential.accessToken {
                return accessToken
            }
        }

        let credential = try await refreshedCredential()
        guard let accessToken = credential.accessToken, !accessToken.isEmpty else {
            throw GoogleTokenError.notSignedIn
        }
        return accessToken
    }

    /// The stored credential, read fresh so a sign-in or sign-out in Settings is
    /// visible immediately.
    public func currentCredential() async throws -> GoogleCredential {
        try await read()
    }

    // MARK: - Refresh

    private func refreshedCredential() async throws -> GoogleCredential {
        if let refreshTask {
            return try await refreshTask.value
        }

        let credential = try await currentCredential()
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            // A readable access token with no refresh token still works until it
            // expires; reuse it rather than failing the whole sync.
            if credential.accessToken?.isEmpty == false {
                return credential
            }
            throw GoogleTokenError.notSignedIn
        }

        let generation = refreshGeneration
        let refresher = self.refresher
        let task = Task { try await refresher(refreshToken) }
        refreshTask = task

        do {
            let refreshed = try await task.value
            if generation == refreshGeneration {
                refreshTask = nil
                refreshGeneration += 1
            }
            return refreshed
        } catch {
            if generation == refreshGeneration {
                refreshTask = nil
                refreshGeneration += 1
            }
            if let tokenError = error as? GoogleTokenError {
                throw tokenError
            }
            throw GoogleTokenError.refreshFailed(error.localizedDescription)
        }
    }

    /// Drops an in-flight refresh after sign-out or a Client ID change.
    public func invalidate() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
    }
}

// MARK: - Live Wiring

public extension GoogleTokenProvider {
    /// The production provider: Keychain reads and refreshes through `AuthService`.
    ///
    /// The Client ID is resolved per refresh, so editing it in Settings takes
    /// effect without relaunching the app.
    static func live(
        authService: AuthService,
        clientId: @escaping @Sendable () -> String
    ) -> GoogleTokenProvider {
        GoogleTokenProvider(
            read: { try await authService.readGoogleCredential() },
            refresher: { _ in
                let id = clientId().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { throw GoogleTokenError.missingClientId }
                return try await authService.refreshGoogleCredential(clientId: id)
            }
        )
    }
}
