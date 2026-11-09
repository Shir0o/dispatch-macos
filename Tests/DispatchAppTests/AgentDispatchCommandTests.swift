import Foundation
import Testing
@testable import DispatchApp

@Suite("Agent Dispatch Command Tests")
struct AgentDispatchCommandTests {

    private func payload(repoPath: String? = nil) -> AgentDispatchPayload {
        AgentDispatchPayload(
            issueNumber: 12,
            repository: "Shir0o/dispatch-macos",
            title: "Fix the browse button",
            body: "The panel opens behind the settings window.",
            comments: [],
            localRepoPath: repoPath.map { URL(fileURLWithPath: $0) }
        )
    }

    // MARK: - Google redirect derivation

    @Test("Callback scheme is derived from the client ID prefix")
    func callbackSchemeDerivedFromClientID() throws {
        let clientID = "123456789012-abcdefghijklmnop.apps.googleusercontent.com"
        let redirect = try AuthService.googleRedirect(for: clientID)
        #expect(redirect.callbackScheme == "com.googleusercontent.apps.123456789012-abcdefghijklmnop")
        #expect(redirect.redirectURI == "com.googleusercontent.apps.123456789012-abcdefghijklmnop:/oauth2redirect")
    }

    @Test("Callback scheme tolerates surrounding whitespace and requires the Google suffix")
    func callbackSchemeToleratesNoisyInput() throws {
        let redirect = try AuthService.googleRedirect(for: "  abc-123.apps.googleusercontent.com  ")
        #expect(redirect.callbackScheme == "com.googleusercontent.apps.abc-123")
        #expect(throws: AuthError.self) {
            try AuthService.googleRedirect(for: "abc-123")
        }
    }

    // MARK: - Shell quoting

    @Test("Shell quoting wraps values and escapes embedded single quotes")
    func shellQuotingEscapesSingleQuotes() {
        #expect(AgentDispatchService.shellQuoted("/Users/twang/My Repo") == "'/Users/twang/My Repo'")
        #expect(AgentDispatchService.shellQuoted("it's") == "'it'\\''s'")
    }

    // MARK: - Command line assembly

    @Test("Command line changes into the local repo and reads the staged prompt")
    func commandLineIncludesRepoAndPromptFile() {
        let promptFile = URL(fileURLWithPath: "/Users/twang/Library/Application Support/Dispatch/dispatch-prompt.md")
        let command = AgentDispatchService.commandLine(
            payload: payload(repoPath: "/Users/twang/dispatch-macos"),
            agent: .opencode,
            agentCommand: "opencode run",
            promptFileURL: promptFile
        )

        #expect(command == "cd '/Users/twang/dispatch-macos' && opencode run \"$(cat '/Users/twang/Library/Application Support/Dispatch/dispatch-prompt.md')\"")
    }

    @Test("Command line omits cd when no local clone is known")
    func commandLineOmitsCDWithoutRepoPath() {
        let promptFile = URL(fileURLWithPath: "/tmp/prompt.md")
        let command = AgentDispatchService.commandLine(
            payload: payload(),
            agent: .claude,
            agentCommand: "claude",
            promptFileURL: promptFile
        )

        #expect(command == "claude \"$(cat '/tmp/prompt.md')\"")
    }

    @Test("Clipboard-only mode produces no command")
    func clipboardOnlyModeHasNoCommand() {
        #expect(AgentDispatchService.commandLine(
            payload: payload(repoPath: "/tmp/repo"),
            agent: .none,
            agentCommand: "opencode run",
            promptFileURL: URL(fileURLWithPath: "/tmp/prompt.md")
        ) == nil)
    }

    @Test("An empty agent command falls back to the raw prompt")
    func emptyCommandFallsBackToPrompt() {
        #expect(AgentDispatchService.commandLine(
            payload: payload(),
            agent: .custom,
            agentCommand: "   ",
            promptFileURL: URL(fileURLWithPath: "/tmp/prompt.md")
        ) == nil)
    }

    @Test("Custom agents keep their user-supplied command verbatim")
    func customAgentKeepsCommand() {
        let command = AgentDispatchService.commandLine(
            payload: payload(repoPath: "/tmp/repo"),
            agent: .custom,
            agentCommand: "aider --yes",
            promptFileURL: URL(fileURLWithPath: "/tmp/prompt.md")
        )

        #expect(command == "cd '/tmp/repo' && aider --yes \"$(cat '/tmp/prompt.md')\"")
    }

    // MARK: - Prompt staging

    @Test("Staged prompt file contains the compiled markdown")
    func stagedPromptFileMatchesPayload() throws {
        let stagedURL = try AgentDispatchService.writePromptFile(payload().formattedPrompt)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        let written = try String(contentsOf: stagedURL, encoding: .utf8)
        #expect(written == payload().formattedPrompt)
        #expect(stagedURL.lastPathComponent == AgentDispatchService.promptFilename)
    }
}
