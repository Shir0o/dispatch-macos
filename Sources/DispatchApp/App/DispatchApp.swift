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
    private let googleTokens: GoogleTokenProvider
    private let gitHubService: GitHubService
    private let syncCoordinator: SyncCoordinator
    private let preferencesRef: PreferencesStore
    private let triageRef: TriageStore

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

        let googleTokens = GoogleTokenProvider.live(authService: auth) {
            UserDefaults.standard.string(forKey: PreferencesStore.googleClientIdDefaultsKey) ?? ""
        }

        let gmail = GmailService(session: .shared) { forceRefresh in
            try await googleTokens.token(forceRefresh: forceRefresh)
        }
        let triage = TriageStore()
        let openWork = OpenWorkStore(
            fetchAction: { try await gitHub.fetchOpenWork() },
            isConfigured: migration.isConfigured
        )

        // The Keychain is the source of truth for Gmail, not the Settings view's
        // per-session state: a refresh token saved by an earlier launch means the
        // app is still signed in after a relaunch.
        preferences.isGoogleConnected = AuthService.hasGoogleRefreshToken()

        let coordinator = SyncCoordinator(gmailService: gmail) { @MainActor in
            await openWork.refreshIfDue()
        }

        _preferencesStore = State(initialValue: preferences)
        _authService = State(initialValue: auth)
        _triageStore = State(initialValue: triage)
        _openWorkStore = State(initialValue: openWork)

        self.gmailService = gmail
        self.googleTokens = googleTokens
        self.gitHubService = gitHub
        self.syncCoordinator = coordinator
        self.preferencesRef = preferences
        self.triageRef = triage
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
            await syncCoordinator.setOnGmailSyncState { [weak triageRef, weak preferencesRef] state in
                Task { @MainActor in
                    triageRef?.setGmailSyncState(state)
                    if state.failureMessage != nil {
                        // A failed sync means the stored grant is no longer usable;
                        // stop claiming the account is connected.
                        preferencesRef?.isGoogleConnected = false
                    } else if state == .connected {
                        preferencesRef?.isGoogleConnected = true
                    }
                }
            }
            await syncCoordinator.start()
        }
    }
}
