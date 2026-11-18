import Foundation
import Testing
@testable import DispatchApp

// MARK: - Force Flag Recorder

private actor TokenRequestRecorder {
    private(set) var flags: [Bool] = []

    func record(_ forceRefresh: Bool) {
        flags.append(forceRefresh)
    }
}

// MARK: - Gmail Auth Recovery

@Suite("Gmail Auth Recovery Tests", .serialized)
struct GmailAuthRecoveryTests {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    @Test("A 401 is retried once with a forced token refresh")
    func retriesUnauthorizedOnce() async throws {
        MockURLProtocol.reset()
        let recorder = TokenRequestRecorder()

        MockURLProtocol.register { request in
            let url = request.url!
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer fresh" {
                return (
                    Self.response(for: url, status: 200),
                    Data(#"{"emailAddress":"me@example.com","historyId":"42"}"#.utf8)
                )
            }
            return (Self.response(for: url, status: 401), Data(#"{"error":"invalid_token"}"#.utf8))
        }

        let service = GmailService(session: makeSession()) { forceRefresh in
            await recorder.record(forceRefresh)
            return forceRefresh ? "fresh" : "stale"
        }

        let profile = try await service.getProfile()

        #expect(profile.emailAddress == "me@example.com")
        #expect(await recorder.flags == [false, true])
    }

    @Test("A second 401 surfaces unauthorized instead of looping")
    func secondUnauthorizedSurfaces() async {
        MockURLProtocol.reset()
        let recorder = TokenRequestRecorder()

        MockURLProtocol.register { request in
            (Self.response(for: request.url!, status: 401), Data(#"{"error":"invalid_token"}"#.utf8))
        }

        let service = GmailService(session: makeSession()) { forceRefresh in
            await recorder.record(forceRefresh)
            return forceRefresh ? "still-bad" : "stale"
        }

        await #expect(throws: GmailError.unauthorized) {
            _ = try await service.getProfile()
        }
        #expect(await recorder.flags == [false, true])
    }
}

// MARK: - Empty State Copy

@Suite("Gmail Empty State Tests")
struct GmailEmptyStateTests {

    @Test("A disconnected account never claims Inbox Zero")
    func disconnected() {
        let state = GmailEmptyState.make(isConnected: false, syncState: .unknown)

        #expect(state.title == "Gmail isn't connected")
        #expect(state.offersSettings == true)
    }

    @Test("A failed sync explains the failure instead of Inbox Zero")
    func failed() {
        let state = GmailEmptyState.make(
            isConnected: true,
            syncState: .failed("Gmail sign-in expired. Sign in again from Settings.")
        )

        #expect(state.title == "Couldn't load Gmail")
        #expect(state.message.contains("expired"))
        #expect(state.offersSettings == true)
    }

    @Test("An empty connected inbox is Inbox Zero")
    func emptyInbox() {
        let state = GmailEmptyState.make(isConnected: true, syncState: .connected)

        #expect(state.title == "Inbox Zero")
        #expect(state.offersSettings == false)
    }

    @Test("Auth failures map to actionable Gmail messages")
    func errorMapping() {
        #expect(
            SyncCoordinator.gmailState(for: GmailError.unauthorized)
                == .failed("Gmail sign-in expired. Sign in again from Settings.")
        )
        #expect(
            SyncCoordinator.gmailState(for: GmailError.missingToken)
                == .failed("Gmail isn't connected. Sign in from Settings.")
        )
        #expect(
            SyncCoordinator.gmailState(for: URLError(.notConnectedToInternet))
                == .failed("No network. Gmail will retry automatically.")
        )
    }
}
