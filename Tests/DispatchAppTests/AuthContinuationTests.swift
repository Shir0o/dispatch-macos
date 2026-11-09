import Foundation
import Testing
@testable import DispatchApp

@Suite("Auth Continuation Tests")
struct AuthContinuationTests {

    private enum TestFailure: Error, Equatable, Sendable {
        case dryRunFailed
    }

    @Test("A duplicate resume is ignored instead of trapping")
    func duplicateResumeIsIgnored() async throws {
        var firstResume: Bool?
        var secondResume: Bool?

        let value: Int = try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<Int>(continuation)
            firstResume = gate.resume(with: .success(1))
            // This is the exact shape of the old crash: the completion handler
            // resumed, then `start()` returning false resumed again.
            secondResume = gate.resume(with: .success(2))
        }

        #expect(value == 1)
        #expect(firstResume == true)
        #expect(secondResume == false)
    }

    @Test("A late success cannot overwrite a failure that was already delivered")
    func failureWinsOverLateSuccess() async {
        var deliveredError: TestFailure?
        var secondResume: Bool?

        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate<Int>(continuation)
                gate.resume(with: .failure(TestFailure.dryRunFailed))
                secondResume = gate.resume(with: .success(42))
            }
            Issue.record("Expected the gate to surface the first result")
        } catch let error as TestFailure {
            deliveredError = error
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(deliveredError == .dryRunFailed)
        #expect(secondResume == false)
    }
}
