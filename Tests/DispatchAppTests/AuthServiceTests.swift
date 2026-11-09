import Foundation
import Testing
@testable import DispatchApp

// MARK: - AuthService Tests

@Suite("AuthService Tests")
struct AuthServiceTests {

    // MARK: - Web Auth Completion

    /// `ASWebAuthenticationSession` invokes its completion handler on the
    /// `com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent` queue, not
    /// on the main queue. This test delivers the callback from a background
    /// queue to prove the handler does not assert main-actor isolation.
    @Test("Web auth completion resumes when Safari calls back off the main thread")
    func webAuthCompletionOffMainThread() async throws {
        let callback = URL(
            string: "com.googleusercontent.apps.123456789012-abcdef:/oauth2redirect?code=abc"
        )!

        let resolved = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, any Error>) in
            Task { @MainActor in
                let handler: @Sendable (URL?, (any Error)?) -> Void =
                    AuthService.makeWebAuthCompletionHandler(ContinuationGate(continuation))
                DispatchQueue.global(qos: .userInitiated).async {
                    handler(callback, nil)
                }
            }
        }

        #expect(resolved == callback)
    }

    @Test("Web auth completion forwards Safari errors")
    func webAuthCompletionForwardsError() async throws {
        struct SampleError: Error, Equatable, Sendable {
            let code: Int
        }
        let expected = SampleError(code: 1)

        await #expect(throws: SampleError.self) {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<URL, any Error>) in
                Task { @MainActor in
                    let handler: @Sendable (URL?, (any Error)?) -> Void =
                        AuthService.makeWebAuthCompletionHandler(ContinuationGate(continuation))
                    DispatchQueue.global(qos: .userInitiated).async {
                        handler(nil, expected)
                    }
                }
            }
        }
    }

    // MARK: - Redirect Derivation

    @Test("Google redirect is derived from the client ID")
    func redirectDerivedFromClientId() throws {
        let redirect = try AuthService.googleRedirect(
            for: "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
        )

        #expect(redirect.callbackScheme == "com.googleusercontent.apps.123456789012-abcdefghijklmnop")
        #expect(redirect.redirectURI == "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauth2redirect")
    }

    @Test("Client IDs that are not Google native clients are rejected")
    func invalidClientIdRejected() {
        #expect(throws: AuthError.self) {
            try AuthService.googleRedirect(for: "dispatch")
        }
        #expect(throws: AuthError.self) {
            try AuthService.googleRedirect(for: "")
        }
        #expect(throws: AuthError.self) {
            try AuthService.googleRedirect(for: "   ")
        }
        #expect(throws: AuthError.self) {
            try AuthService.googleRedirect(for: ".apps.googleusercontent.com")
        }
    }
}
