import Foundation
import Testing
@testable import DispatchApp

// MARK: - Recorder

private actor RefreshRecorder {
    private(set) var count = 0

    func record() -> Int {
        count += 1
        return count
    }
}

// MARK: - Tests

@Suite("Google Token Provider Tests")
struct GoogleTokenProviderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeProvider(
        credential: GoogleCredential,
        recorder: RefreshRecorder,
        refreshed: GoogleCredential? = nil,
        sleepNanoseconds: UInt64 = 0
    ) -> GoogleTokenProvider {
        GoogleTokenProvider(
            leeway: 60,
            now: { self.now },
            read: { credential },
            refresher: { _ in
                _ = await recorder.record()
                if sleepNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: sleepNanoseconds)
                }
                guard let refreshed else { throw GoogleTokenError.refreshFailed("no token") }
                return refreshed
            }
        )
    }

    @Test("A token with time left is returned without refreshing")
    func validTokenSkipsRefresh() async throws {
        let recorder = RefreshRecorder()
        let provider = makeProvider(
            credential: GoogleCredential(
                accessToken: "cached",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(3_600)
            ),
            recorder: recorder
        )

        #expect(try await provider.token() == "cached")
        #expect(await recorder.count == 0)
    }

    @Test("An expired token is refreshed before it is returned")
    func expiredTokenRefreshes() async throws {
        let recorder = RefreshRecorder()
        let provider = makeProvider(
            credential: GoogleCredential(
                accessToken: "expired",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(-1)
            ),
            recorder: recorder,
            refreshed: GoogleCredential(
                accessToken: "fresh",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(3_600)
            )
        )

        #expect(try await provider.token() == "fresh")
        #expect(await recorder.count == 1)
    }

    @Test("A token from a previous session with no expiry is refreshed")
    func missingExpiryRefreshes() async throws {
        let recorder = RefreshRecorder()
        let provider = makeProvider(
            credential: GoogleCredential(
                accessToken: "old",
                refreshToken: "refresh",
                expiry: nil
            ),
            recorder: recorder,
            refreshed: GoogleCredential(
                accessToken: "fresh",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(3_600)
            )
        )

        #expect(try await provider.token() == "fresh")
        #expect(await recorder.count == 1)
    }

    @Test("A forced refresh replaces a token that still looks valid")
    func forcedRefresh() async throws {
        let recorder = RefreshRecorder()
        let provider = makeProvider(
            credential: GoogleCredential(
                accessToken: "rejected",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(3_600)
            ),
            recorder: recorder,
            refreshed: GoogleCredential(
                accessToken: "fresh",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(3_600)
            )
        )

        #expect(try await provider.token(forceRefresh: true) == "fresh")
        #expect(await recorder.count == 1)
    }

    @Test("Concurrent callers share a single refresh")
    func concurrentCallersRefreshOnce() async throws {
        let recorder = RefreshRecorder()
        let provider = makeProvider(
            credential: GoogleCredential(
                accessToken: "expired",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(-1)
            ),
            recorder: recorder,
            refreshed: GoogleCredential(
                accessToken: "fresh",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(3_600)
            ),
            sleepNanoseconds: 50_000_000
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await provider.token() }
            }
            var values: [String] = []
            for try await token in group {
                values.append(token)
            }
            return values
        }

        #expect(tokens.count == 20)
        #expect(Set(tokens) == ["fresh"])
        #expect(await recorder.count == 1)
    }

    @Test("No credential at all reports not signed in")
    func missingCredential() async {
        let recorder = RefreshRecorder()
        let provider = makeProvider(
            credential: GoogleCredential(accessToken: nil, refreshToken: nil, expiry: nil),
            recorder: recorder
        )

        await #expect(throws: GoogleTokenError.notSignedIn) {
            try await provider.token()
        }
    }

    @Test("A failed refresh is reported with the underlying reason")
    func refreshFailure() async {
        let recorder = RefreshRecorder()
        let provider = makeProvider(
            credential: GoogleCredential(
                accessToken: "expired",
                refreshToken: "refresh",
                expiry: now.addingTimeInterval(-1)
            ),
            recorder: recorder,
            refreshed: nil
        )

        do {
            _ = try await provider.token()
            Issue.record("Expected refreshFailed")
        } catch let error as GoogleTokenError {
            #expect(error == .refreshFailed("no token"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
