import Foundation
import AppKit

// MARK: - AgentDispatchError

public enum AgentDispatchError: LocalizedError, Sendable, Equatable {
    case applicationNotFound(bundleIdentifier: String)
    case dispatchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound(let bundleId):
            return "Application with bundle identifier '\(bundleId)' was not found on this Mac."
        case .dispatchFailed(let reason):
            return "Failed to open application: \(reason)"
        }
    }
}

// MARK: - AgentDispatchService

public final class AgentDispatchService: Sendable {
    public init() {}

    @MainActor
    public func copyToPasteboard(prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }

    public func dispatch(
        payload: AgentDispatchPayload,
        preferredTerminal: TerminalApp
    ) async throws {
        // 1. Copy formatted prompt to NSPasteboard.general on @MainActor
        await copyToPasteboard(prompt: payload.formattedPrompt)

        // 2. Locate the preferred application by bundle identifier
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredTerminal.bundleIdentifier) else {
            throw AgentDispatchError.applicationNotFound(bundleIdentifier: preferredTerminal.bundleIdentifier)
        }

        // 3. Activate the application via NSWorkspace.shared.openApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw AgentDispatchError.dispatchFailed(error.localizedDescription)
        }
    }
}
