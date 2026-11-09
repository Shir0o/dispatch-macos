import SwiftUI
import AppKit

/// Three-column navigation layout hosting the sidebar, virtualized stream, and
/// detail inspector, with Vim/Superhuman single-key shortcut dispatch.
public struct MainSplitView: View {
    @Environment(TriageStore.self) private var store
    @Environment(PreferencesStore.self) private var preferencesStore
    @FocusState private var isSearchFocused: Bool

    public init() {}

    public var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView()
            } content: {
                TriageStreamView()
            } detail: {
                DetailPaneView()
            }
            .navigationSplitViewStyle(.balanced)

            // Onboarding display if no accounts configured and inboxes are empty
            if isFirstLaunchEmptyState {
                OnboardingView()
                    .transition(.opacity)
            }

            // Invisible keyboard shortcut receivers guarded by focus state
            keyboardShortcutTriggers
        }
    }

    private var isFirstLaunchEmptyState: Bool {
        preferencesStore.googleClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        preferencesStore.githubPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        store.gmailItems.isEmpty &&
        store.gitHubItems.isEmpty
    }

    // MARK: - Keyboard Shortcut Triggers

    @ViewBuilder
    private var keyboardShortcutTriggers: some View {
        Group {
            // j: Next item
            Button("Next Item") {
                guard !isSearchFocused else { return }
                store.selectNext()
            }
            .keyboardShortcut("j", modifiers: [])

            // k: Previous item
            Button("Previous Item") {
                guard !isSearchFocused else { return }
                store.selectPrevious()
            }
            .keyboardShortcut("k", modifiers: [])

            // e: Archive / dismiss
            Button("Archive") {
                guard !isSearchFocused, let item = store.selectedItem else { return }
                store.archive(item: item)
            }
            .keyboardShortcut("e", modifiers: [])

            // s: Star
            Button("Star") {
                guard !isSearchFocused, let item = store.selectedItem else { return }
                store.star(item: item)
            }
            .keyboardShortcut("s", modifiers: [])

            // u: Unread
            Button("Toggle Unread") {
                guard !isSearchFocused, let item = store.selectedItem else { return }
                store.markUnread(item: item)
            }
            .keyboardShortcut("u", modifiers: [])

            // #: Trash / Unsubscribe
            Button("Trash") {
                guard !isSearchFocused, let item = store.selectedItem else { return }
                store.trash(item: item)
            }
            .keyboardShortcut(KeyEquivalent("#"), modifiers: [])

            // Cmd+Shift+A: Dispatch selected issue to local coding agent
            Button("Dispatch to Agent") {
                guard !isSearchFocused else { return }
                dispatchCurrentItem()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            // Cmd+O: Open selected item in default web browser
            Button("Open in Browser") {
                guard let item = store.selectedItem else { return }
                NSWorkspace.shared.open(item.webURL)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
    }

    // MARK: - Dispatch Helper

    private func dispatchCurrentItem() {
        guard let item = store.selectedItem else { return }

        let repo: String
        let number: Int
        switch item.kind {
        case .gitHubIssue(let n, let r, _, _):
            number = n
            repo = r
        case .gitHubPullRequest(let n, let r, _, _, _):
            number = n
            repo = r
        default:
            store.showToast("Select a GitHub issue or PR to dispatch")
            return
        }

        let localPath = preferencesStore.localPath(for: repo)
        let payload = AgentDispatchPayload(
            issueNumber: number,
            repository: repo,
            title: item.title,
            body: item.title,
            comments: [],
            localRepoPath: localPath
        )

        Task {
            do {
                try await AgentDispatchService().dispatch(
                    payload: payload,
                    preferredTerminal: preferencesStore.preferredTerminal,
                    agent: preferencesStore.preferredAgent,
                    agentCommand: preferencesStore.agentCommand
                )
                store.showToast(preferencesStore.preferredAgent == .none
                    ? "Copied issue context to clipboard"
                    : "Copied \(preferencesStore.preferredAgent.rawValue) command — paste in your terminal")
            } catch {
                store.showToast("Dispatch error: \(error.localizedDescription)")
            }
        }
    }
}
