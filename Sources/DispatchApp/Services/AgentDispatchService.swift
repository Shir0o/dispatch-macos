import Foundation
import AppKit

// MARK: - AgentDispatchError

public enum AgentDispatchError: LocalizedError, Sendable, Equatable {
    case applicationNotFound(bundleIdentifier: String)
    case dispatchFailed(String)
    case promptFileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound(let bundleId):
            return "Application with bundle identifier '\(bundleId)' was not found on this Mac."
        case .dispatchFailed(let reason):
            return "Failed to open application: \(reason)"
        case .promptFileWriteFailed(let reason):
            return "Failed to write the dispatch prompt: \(reason)"
        }
    }
}

// MARK: - AgentDispatchService

public final class AgentDispatchService: Sendable {
    public init() {}

    /// Filename used to stage the compiled prompt for the CLI agent.
    public static let promptFilename = "dispatch-prompt.md"

    @MainActor
    public func copyToPasteboard(prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }

    /// Writes the compiled prompt to Application Support so the terminal command
    /// can read it without shell-quoting a multi-line markdown document.
    public static func writePromptFile(_ prompt: String) throws -> URL {
        let fileManager = FileManager.default
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Dispatch", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(promptFilename, isDirectory: false)
        try prompt.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Quotes a value for a POSIX shell, wrapping it in single quotes.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds the command a user pastes into their terminal to start the agent
    /// with the staged prompt. Returns `nil` for the clipboard-only mode.
    public static func commandLine(
        payload: AgentDispatchPayload,
        agent: AgentCLI,
        agentCommand: String,
        promptFileURL: URL?
    ) -> String? {
        let command = agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agent != .none, !command.isEmpty, let promptFileURL else {
            return nil
        }

        var parts: [String] = []
        if let repoPath = payload.localRepoPath {
            parts.append("cd \(shellQuoted(repoPath.path))")
        }
        parts.append("\(command) \"$(cat \(shellQuoted(promptFileURL.path)))\"")
        return parts.joined(separator: " && ")
    }

    /// Copies the dispatch payload to the pasteboard and brings the preferred
    /// terminal to the front.
    ///
    /// The app is sandboxed, so it never executes the agent itself: it stages the
    /// prompt, copies a ready-to-run command, and lets the user paste and press
    /// Return in their own shell. That keeps script-injection surface at zero.
    @discardableResult
    public func dispatch(
        payload: AgentDispatchPayload,
        preferredTerminal: TerminalApp,
        agent: AgentCLI = .none,
        agentCommand: String = ""
    ) async throws -> String {
        var promptFileURL: URL?
        if agent != .none {
            do {
                promptFileURL = try Self.writePromptFile(payload.formattedPrompt)
            } catch {
                throw AgentDispatchError.promptFileWriteFailed(error.localizedDescription)
            }
        }

        let command = Self.commandLine(
            payload: payload,
            agent: agent,
            agentCommand: agentCommand,
            promptFileURL: promptFileURL
        )
        let clipboardText = command ?? payload.formattedPrompt

        await copyToPasteboard(prompt: clipboardText)

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredTerminal.bundleIdentifier) else {
            throw AgentDispatchError.applicationNotFound(bundleIdentifier: preferredTerminal.bundleIdentifier)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw AgentDispatchError.dispatchFailed(error.localizedDescription)
        }

        return clipboardText
    }
}
