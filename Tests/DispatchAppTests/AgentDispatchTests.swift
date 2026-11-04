import Foundation
import Testing
import AppKit
@testable import DispatchApp

@Suite("AgentDispatch Tests")
struct AgentDispatchTests {

    // MARK: - Prompt Compilation Tests

    @Test("Formatted prompt generates valid markdown structure with task header, title, description, and comments")
    func testFormattedPromptBasicStructure() {
        let payload = AgentDispatchPayload(
            issueNumber: 42,
            repository: "apple/swift",
            title: "Improve actor isolation diagnostics in Swift 6 mode",
            body: "When cross-isolation calls occur, diagnostic notes should suggest `nonisolated(unsafe)`.",
            comments: [],
            localRepoPath: nil
        )

        let prompt = payload.formattedPrompt

        #expect(prompt.contains("# Task: Address GitHub Issue #42 in apple/swift"))
        #expect(prompt.contains("Title: Improve actor isolation diagnostics in Swift 6 mode"))
        #expect(prompt.contains("## Description\nWhen cross-isolation calls occur, diagnostic notes should suggest `nonisolated(unsafe)`."))
        #expect(prompt.contains("## Comments\nNo comments."))
        #expect(!prompt.contains("Local Path:"))
    }

    @Test("Formatted prompt includes local repository path when configured")
    func testFormattedPromptWithLocalPath() {
        let repoURL = URL(fileURLWithPath: "/Users/developer/Projects/dev-triage-macos")
        let payload = AgentDispatchPayload(
            issueNumber: 101,
            repository: "twang/dev-triage-macos",
            title: "Add keyboard navigation shortcuts",
            body: "Single-key shortcuts (j/k) should navigate through stream items.",
            comments: [],
            localRepoPath: repoURL
        )

        let prompt = payload.formattedPrompt

        #expect(prompt.contains("Local Path: /Users/developer/Projects/dev-triage-macos"))
        #expect(prompt.contains("# Task: Address GitHub Issue #101 in twang/dev-triage-macos"))
        #expect(prompt.contains("Title: Add keyboard navigation shortcuts"))
        #expect(prompt.contains("## Description"))
    }

    @Test("Formatted prompt omits Local Path line when path is nil")
    func testFormattedPromptOmitsLocalPathWhenNil() {
        let payload = AgentDispatchPayload(
            issueNumber: 7,
            repository: "org/repo",
            title: "Remote issue without local clone",
            body: "Investigate crash log.",
            comments: [],
            localRepoPath: nil
        )

        let prompt = payload.formattedPrompt
        #expect(!prompt.contains("Local Path:"))
    }

    @Test("Formatted prompt compiles empty comments section gracefully")
    func testFormattedPromptEmptyComments() {
        let payload = AgentDispatchPayload(
            issueNumber: 1,
            repository: "acme/api",
            title: "Fresh issue",
            body: "No discussion yet.",
            comments: []
        )

        let prompt = payload.formattedPrompt
        #expect(prompt.hasSuffix("## Comments\nNo comments."))
    }

    @Test("Formatted prompt compiles single comment with author, timestamp, and body")
    func testFormattedPromptSingleComment() {
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let comment = GitHubComment(
            id: 1,
            author: "alice",
            body: "I can reproduce this deterministically on macOS 14.5.",
            createdAt: timestamp
        )

        let payload = AgentDispatchPayload(
            issueNumber: 15,
            repository: "acme/widget",
            title: "Button alignment shift",
            body: "Under high display scaling, the button shifts by 2pt.",
            comments: [comment]
        )

        let prompt = payload.formattedPrompt

        #expect(prompt.contains("## Comments"))
        #expect(prompt.contains("### @alice on \(timestamp):"))
        #expect(prompt.contains("I can reproduce this deterministically on macOS 14.5."))
        #expect(!prompt.contains("---"))
    }

    @Test("Formatted prompt compiles timeline of multiple comments separated by markdown horizontal rules")
    func testFormattedPromptMultipleCommentsTimeline() {
        let date1 = Date(timeIntervalSince1970: 1700000000)
        let date2 = Date(timeIntervalSince1970: 1700003600)
        let date3 = Date(timeIntervalSince1970: 1700007200)

        let c1 = GitHubComment(id: 1, author: "alice", body: "First report with reproduction steps.", createdAt: date1)
        let c2 = GitHubComment(id: 2, author: "bob", body: "Confirmed. Root cause is race in actor mailbox.", createdAt: date2)
        let c3 = GitHubComment(id: 3, author: "charlie", body: "Draft PR submitted with regression test.", createdAt: date3)

        let payload = AgentDispatchPayload(
            issueNumber: 88,
            repository: "swiftlang/swift-syntax",
            title: "Race condition during concurrent parsing",
            body: "Calling parse concurrent from multiple threads causes abort.",
            comments: [c1, c2, c3]
        )

        let prompt = payload.formattedPrompt

        #expect(prompt.contains("### @alice on \(date1):\nFirst report with reproduction steps."))
        #expect(prompt.contains("\n\n---\n\n"))
        #expect(prompt.contains("### @bob on \(date2):\nConfirmed. Root cause is race in actor mailbox."))
        #expect(prompt.contains("### @charlie on \(date3):\nDraft PR submitted with regression test."))

        // Verify ordering: alice comes before bob, bob comes before charlie
        guard let rangeAlice = prompt.range(of: "@alice"),
              let rangeBob = prompt.range(of: "@bob"),
              let rangeCharlie = prompt.range(of: "@charlie") else {
            Issue.record("Failed to find comment author ranges in formatted prompt")
            return
        }

        #expect(rangeAlice.upperBound < rangeBob.lowerBound)
        #expect(rangeBob.upperBound < rangeCharlie.lowerBound)
    }

    @Test("Formatted prompt preserves multiline markdown and code blocks in issue body")
    func testFormattedPromptMultilineBodyAndCodeBlocks() {
        let multilineBody = """
        ### Environment
        - OS: macOS 14.4
        - Xcode: 16.0

        ### Reproduction
        ```swift
        let actor = SyncCoordinator()
        await actor.performSyncCycle()
        ```

        > [!IMPORTANT]
        > High priority regression blocking release.
        """

        let payload = AgentDispatchPayload(
            issueNumber: 99,
            repository: "org/project",
            title: "Crash in performSyncCycle",
            body: multilineBody,
            comments: []
        )

        let prompt = payload.formattedPrompt

        #expect(prompt.contains("```swift\nlet actor = SyncCoordinator()"))
        #expect(prompt.contains("> [!IMPORTANT]"))
        #expect(prompt.contains("- OS: macOS 14.4"))
    }

    @Test("Formatted prompt correctly handles special characters, quotes, and unicode in titles and bodies")
    func testFormattedPromptSpecialCharactersAndUnicode() {
        let specialTitle = "[Bug 🚨] Issue with \"quotes\", <brackets>, & `backticks` in title"
        let specialBody = "Testing emoji support 🚀, kanji 日本語, and special symbols: § ¶ • €."

        let payload = AgentDispatchPayload(
            issueNumber: 12,
            repository: "unicode/test-repo",
            title: specialTitle,
            body: specialBody,
            comments: []
        )

        let prompt = payload.formattedPrompt

        #expect(prompt.contains("Title: [Bug 🚨] Issue with \"quotes\", <brackets>, & `backticks` in title"))
        #expect(prompt.contains("Testing emoji support 🚀, kanji 日本語, and special symbols: § ¶ • €."))
    }

    // MARK: - TerminalApp Bundle Identifier Mappings

    @Test("TerminalApp bundle identifiers map to expected macOS bundle IDs")
    func testTerminalAppBundleIdentifierMappings() {
        #expect(TerminalApp.terminal.bundleIdentifier == "com.apple.Terminal")
        #expect(TerminalApp.iterm2.bundleIdentifier == "com.googlecode.iterm2")
        #expect(TerminalApp.ghostty.bundleIdentifier == "com.mitchellh.ghostty")
        #expect(TerminalApp.vscode.bundleIdentifier == "com.microsoft.VSCode")
        #expect(TerminalApp.alacritty.bundleIdentifier == "org.alacritty")
    }

    @Test("TerminalApp allCases are exhaustive and identify with raw values")
    func testTerminalAppCasesAndIdentifiable() {
        let allCases = TerminalApp.allCases
        #expect(allCases.count == 5)

        for app in allCases {
            #expect(!app.bundleIdentifier.isEmpty)
            #expect(app.id == app.rawValue)
        }
    }

    @Test("TerminalApp roundtrips through JSON encoding and decoding")
    func testTerminalAppCodableRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for app in TerminalApp.allCases {
            let data = try encoder.encode(app)
            let decoded = try decoder.decode(TerminalApp.self, from: data)
            #expect(decoded == app)
        }
    }

    // MARK: - AgentDispatchError and Service Tests

    @Test("AgentDispatchError descriptions provide clear diagnostic messages")
    func testAgentDispatchErrorDescriptions() {
        let notFound = AgentDispatchError.applicationNotFound(bundleIdentifier: "com.custom.terminal")
        #expect(notFound.errorDescription == "Application with bundle identifier 'com.custom.terminal' was not found on this Mac.")

        let failed = AgentDispatchError.dispatchFailed("Application is unresponsive")
        #expect(failed.errorDescription == "Failed to open application: Application is unresponsive")
    }

    @Test("AgentDispatchService copies prompt to general pasteboard on @MainActor")
    @MainActor
    func testAgentDispatchPasteboardCopy() {
        let service = AgentDispatchService()
        let testPrompt = "Test agent dispatch prompt #\(UUID().uuidString)"

        service.copyToPasteboard(prompt: testPrompt)

        let copied = NSPasteboard.general.string(forType: .string)
        #expect(copied == testPrompt)
    }

    @Test("PreferencesStore resolves local repository path within configured projects directory")
    @MainActor
    func testPreferencesStoreLocalPathResolution() {
        let defaults = UserDefaults(suiteName: "com.dispatch.test.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: "com.dispatch.test.\(UUID().uuidString)") }

        let prefs = PreferencesStore(defaults: defaults)
        prefs.projectsDirectory = "/tmp/DispatchTestProjects"

        let resolved = prefs.localPath(for: "owner/my-cool-project")
        #expect(resolved != nil)
        #expect(resolved?.lastPathComponent == "my-cool-project")
        #expect(resolved?.path.contains("/tmp/DispatchTestProjects") == true)
    }
}
