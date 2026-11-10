import Foundation
import Testing
@testable import DispatchApp

// MARK: - Refresh counter

actor RefreshCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// Covers the coordinator's trigger contract only: `start()` and the wake
/// handler invoke the Open Work refresh closure, and a second `start()` is a
/// no-op. The 15-minute due interval and first-fetch behavior are covered by
/// `OpenWorkStoreTests`, which owns an injected clock.
@Suite("Open Work Coordinator Tests")
struct OpenWorkCoordinatorTests {

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeGmailService(session: URLSession) -> GmailService {
        GmailService(session: session) {
            "mock-gmail-token"
        }
    }

    private func registerGmailHandlers() {
        MockURLProtocol.reset()
        MockURLProtocol.register { request in
            guard let url = request.url?.absoluteString else { return nil }

            if url.contains("/profile") {
                let body = """
                {
                    "emailAddress": "user@example.com",
                    "historyId": "1000",
                    "messagesTotal": 0,
                    "threadsTotal": 0
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }

            if url.contains("/threads?") {
                let body = """
                {
                    "threads": [],
                    "nextPageToken": null,
                    "resultSizeEstimate": 0
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }

            return nil
        }
    }

    private func waitForCount(
        _ counter: RefreshCounter,
        atLeast target: Int
    ) async -> Int {
        for _ in 0..<100 {
            let value = await counter.value
            if value >= target { return value }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await counter.value
    }

    @Test("start() invokes the refresh closure once and a second start does nothing")
    func testStartInvokesRefreshClosureOnce() async throws {
        registerGmailHandlers()
        let counter = RefreshCounter()
        let gmail = makeGmailService(session: makeMockSession())

        let coordinator = SyncCoordinator(gmailService: gmail) {
            await counter.increment()
        }

        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        #expect(await counter.value == 1)

        await coordinator.start()
        #expect(await counter.value == 1)
    }

    @Test("Wake handler invokes the refresh closure")
    func testWakeHandlerInvokesRefreshClosure() async throws {
        registerGmailHandlers()
        let counter = RefreshCounter()
        let gmail = makeGmailService(session: makeMockSession())

        let coordinator = SyncCoordinator(gmailService: gmail) {
            await counter.increment()
        }

        await coordinator.start()
        defer {
            Task {
                await coordinator.stop()
            }
        }

        #expect(await counter.value == 1)

        await coordinator.handleSystemWillSleep()
        await coordinator.handleSystemDidWake()

        let value = await waitForCount(counter, atLeast: 2)
        #expect(value >= 2)
    }
}
