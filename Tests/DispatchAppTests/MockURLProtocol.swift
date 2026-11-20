import Foundation

/// The stubbed network every test file shares.
///
/// Swift Testing runs suites in parallel, and this mock's handler list used to
/// be one process-wide array: a test in one file calling `reset()` cleared a
/// test in another file, so a bootstrap could pick up the wrong history id.
/// Handlers are keyed by the `X-Mock-Session` header instead. Each test file
/// registers under its own constant and its suites are `.serialized`, so tests
/// inside a file cannot race either.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)?

    /// Header `makeMockSession()` sets and handlers are keyed by.
    static let sessionHeader = "X-Mock-Session"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: [RequestHandler]] = [:]

    static func reset(_ session: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: session)
    }

    static func register(_ session: String, _ handler: @escaping RequestHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[session, default: []].append(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let session = request.value(forHTTPHeaderField: Self.sessionHeader) ?? ""
        Self.lock.lock()
        let currentHandlers = Self.handlers[session] ?? []
        Self.lock.unlock()

        for handler in currentHandlers {
            do {
                if let (response, data) = try handler(request) {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }

        // Default 404 fallback
        let url = request.url ?? URL(string: "https://mock.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"error\": \"not found\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
