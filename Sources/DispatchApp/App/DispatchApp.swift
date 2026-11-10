import SwiftUI
import AppKit

/// Composition root and application lifecycle entrypoint for Dispatch.
@main
struct DispatchApp: App {
    @State private var preferencesStore: PreferencesStore
    @State private var authService: AuthService
    @State private var triageStore: TriageStore
    @State private var openWorkStore: OpenWorkStore
    @State private var hasStarted = false

    private let gmailService: GmailService
    private let gitHubService: GitHubService
    private let syncCoordinator: SyncCoordinator

    init() {
        let auth = AuthService()

        // Migration runs before the store exists: it copies the legacy PAT to
        // the Keychain and seeds the Open Work hidden keys from the old state.
        let migration = LegacyStateMigrator.run()

        let preferences = PreferencesStore()
        preferences.isGitHubConfigured = migration.isConfigured

        let gitHub = GitHubService { [auth] in
            // Keychain only. A failed migration leaves the old defaults value
            // behind for manual recovery but never feeds this provider.
            guard let token = try await auth.readKeychainValue(key: AuthService.gitHubPATKey),
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitHubError.missingToken
            }
            return token
        }

        let gmail = GmailService(authService: auth)
        let triage = TriageStore()
        let openWork = OpenWorkStore(
            fetchAction: { try await gitHub.fetchOpenWork() },
            isConfigured: migration.isConfigured
        )

        let coordinator = SyncCoordinator(gmailService: gmail) { @MainActor in
            await openWork.refreshIfDue()
        }

        _preferencesStore = State(initialValue: preferences)
        _authService = State(initialValue: auth)
        _triageStore = State(initialValue: triage)
        _openWorkStore = State(initialValue: openWork)

        self.gmailService = gmail
        self.gitHubService = gitHub
        self.syncCoordinator = coordinator
    }

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environment(preferencesStore)
                .environment(\.authService, authService)
                .environment(triageStore)
                .environment(openWorkStore)
                .frame(minWidth: 900, minHeight: 550)
                .onAppear {
                    setupServicesAndSync()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    triageStore.saveSnapshotSync()
                }
        }
        .defaultSize(width: 1150, height: 720)

        Settings {
            SettingsView()
                .environment(preferencesStore)
                .environment(\.authService, authService)
                .environment(triageStore)
                .environment(openWorkStore)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateController.shared.checkForUpdates()
                }
            }
        }
    }

    // MARK: - Composition Root Wiring

    private func setupServicesAndSync() {
        guard !hasStarted else { return }
        hasStarted = true

        triageStore.authService = authService
        triageStore.gmailService = gmailService
        triageStore.githubService = gitHubService

        // Load disk snapshot immediately for sub-50ms cold start
        triageStore.loadSnapshot()

        Task {
            await syncCoordinator.setOnItemsUpdated { [weak triageStore] items, source in
                Task { @MainActor in
                    triageStore?.setItems(items, for: source)
                }
            }
            await syncCoordinator.start()
        }
    }
}
