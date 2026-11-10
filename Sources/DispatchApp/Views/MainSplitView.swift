import SwiftUI
import AppKit

/// Three-column navigation layout hosting the sidebar, the active workspace
/// stream, and the detail inspector, with Vim/Superhuman single-key shortcuts
/// routed through the active workspace.
public struct MainSplitView: View {
    @Environment(TriageStore.self) private var store
    @Environment(OpenWorkStore.self) private var openWorkStore
    @Environment(PreferencesStore.self) private var preferencesStore
    @FocusState private var isSearchFocused: Bool

    /// Set when a GitHub dispatch could not load issue detail. Drives the
    /// "Send title only / Cancel" alert.
    @State private var dispatchFailureItem: OpenWorkItem?

    public init() {}

    public var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView()
            } content: {
                if store.activeWorkspace == .gitHub {
                    OpenWorkView()
                } else {
                    TriageStreamView()
                }
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
        .alert(
            "Couldn't load issue details",
            isPresented: Binding(
                get: { dispatchFailureItem != nil },
                set: { if !$0 { dispatchFailureItem = nil } }
            ),
            presenting: dispatchFailureItem
        ) { item in
            Button("Send title only") {
                dispatchTitleOnly(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The issue body and comments could not be fetched. Send the title only, or cancel and try again.")
        }
    }

    private var isFirstLaunchEmptyState: Bool {
        preferencesStore.googleClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !preferencesStore.isGitHubConfigured &&
        store.gmailItems.isEmpty
    }

    // MARK: - Keyboard Shortcut Triggers

    @ViewBuilder
    private var keyboardShortcutTriggers: some View {
        Group {
            // j: Next item
            Button("Next Item") {
                guard !isSearchFocused else { return }
                if store.activeWorkspace == .gitHub {
                    openWorkStore.selectNext()
                } else {
                    store.selectNext()
                }
            }
            .keyboardShortcut("j", modifiers: [])

            // k: Previous item
            Button("Previous Item") {
                guard !isSearchFocused else { return }
                if store.activeWorkspace == .gitHub {
                    openWorkStore.selectPrevious()
                } else {
                    store.selectPrevious()
                }
            }
            .keyboardShortcut("k", modifiers: [])

            // e: Archive in Gmail, hide in Open Work
            Button("Archive") {
                guard !isSearchFocused else { return }
                if store.activeWorkspace == .gitHub {
                    guard let item = openWorkStore.selectedItem else { return }
                    openWorkStore.hide(key: item.key)
                } else {
                    guard let item = store.selectedItem else { return }
                    store.archive(item: item)
                }
            }
            .keyboardShortcut("e", modifiers: [])

            // s: Star (Gmail only)
            Button("Star") {
                if store.activeWorkspace == .gitHub {
                    store.showToast("Not available in Open Work")
                    return
                }
                guard let item = store.selectedItem else { return }
                store.star(item: item)
            }
            .keyboardShortcut("s", modifiers: [])

            // u: Unread (Gmail only)
            Button("Toggle Unread") {
                if store.activeWorkspace == .gitHub {
                    store.showToast("Not available in Open Work")
                    return
                }
                guard let item = store.selectedItem else { return }
                store.markUnread(item: item)
            }
            .keyboardShortcut("u", modifiers: [])

            // #: Trash / Unsubscribe (Gmail only)
            Button("Trash") {
                if store.activeWorkspace == .gitHub {
                    store.showToast("Not available in Open Work")
                    return
                }
                guard let item = store.selectedItem else { return }
                store.trash(item: item)
            }
            .keyboardShortcut(KeyEquivalent("#"), modifiers: [])

            // Cmd+Shift+A: Dispatch selected item to a local coding agent
            Button("Dispatch to Agent") {
                guard !isSearchFocused else { return }
                dispatchCurrentItem()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            // Cmd+O: Open selected item on the web
            Button("Open in Browser") {
                if store.activeWorkspace == .gitHub {
                    guard let item = openWorkStore.selectedItem else { return }
                    NSWorkspace.shared.open(item.webURL)
                } else if let item = store.selectedItem {
                    NSWorkspace.shared.open(item.webURL)
                }
            }
            .keyboardShortcut("o", modifiers: [.command])

            // Cmd+Z: Undo the most recent Open Work hide
            Button("Undo Hide") {
                guard store.activeWorkspace == .gitHub else { return }
                guard openWorkStore.canUndo, let key = openWorkStore.lastHiddenKey else { return }
                openWorkStore.unhide(key: key)
            }
            .keyboardShortcut("z", modifiers: [.command])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .frame(width: 0, height: 0)
    }

    // MARK: - Dispatch

    private func dispatchCurrentItem() {
        switch store.activeWorkspace {
        case .gmail:
            dispatchGmailItem()
        case .gitHub:
            guard let item = openWorkStore.selectedItem else {
                store.showToast("Select an Open Work item to dispatch")
                return
            }
            dispatchOpenWorkItem(item)
        }
    }

    /// Gmail keeps the existing refusal for non-GitHub items.
    ///
    /// Every Gmail item is an email now, and Open Work owns GitHub dispatch, so
    /// this path has nothing it can dispatch.
    private func dispatchGmailItem() {
        guard store.selectedItem != nil else { return }
        store.showToast("Select a GitHub issue or PR to dispatch")
    }

    /// Fetches detail, then builds and performs the Open Work dispatch. A detail
    /// failure offers "Send title only" through `dispatchFailureItem`.
    private func dispatchOpenWorkItem(_ item: OpenWorkItem) {
        Task {
            let detail: GitHubIssueDetail?
            do {
                detail = try await store.githubService?.fetchIssueDetails(
                    repo: item.repository,
                    number: item.number
                )
            } catch {
                dispatchFailureItem = item
                return
            }

            do {
                try await OpenWorkDispatcher.performDispatch(
                    payload: OpenWorkDispatcher.makePayload(item: item, detail: detail),
                    preferences: preferencesStore
                )
                store.showToast(dispatchToast())
            } catch {
                store.showToast("Dispatch error: \(error.localizedDescription)")
            }
        }
    }

    private func dispatchTitleOnly(_ item: OpenWorkItem) {
        Task {
            do {
                try await OpenWorkDispatcher.performDispatch(
                    payload: OpenWorkDispatcher.makeTitleOnlyPayload(item: item),
                    preferences: preferencesStore
                )
                store.showToast(dispatchToast())
            } catch {
                store.showToast("Dispatch error: \(error.localizedDescription)")
            }
        }
    }

    private func dispatchToast() -> String {
        preferencesStore.preferredAgent == .none
            ? "Copied issue context to clipboard"
            : "Copied \(preferencesStore.preferredAgent.rawValue) command — paste in your terminal"
    }
}
