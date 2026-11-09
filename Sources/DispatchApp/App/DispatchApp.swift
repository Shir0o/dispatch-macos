import SwiftUI
import AppKit

/// Composition root and application lifecycle entrypoint for Dispatch.
@main
struct DispatchApp: App {
    @State private var preferencesStore = PreferencesStore()
    @State private var authService = AuthService()
    @State private var triageStore = TriageStore()
    @State private var syncCoordinator: SyncCoordinator?

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environment(preferencesStore)
                .environment(\.authService, authService)
                .environment(triageStore)
                .frame(minWidth: 900, minHeight: 550)
                .onAppear {
                    setupServicesAndSync()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    triageStore.saveSnapshotSync()
                }
                .onReceive(NotificationCenter.default.publisher(for: .dispatchGitHubBackfillRequested)) { _ in
                    let coordinator = syncCoordinator
                    let repositories = preferencesStore.normalizedTrackedRepositories
                    let owners = preferencesStore.normalizedTrackedOwners
                    let login = preferencesStore.githubUsername
                    Task {
                        await coordinator?.performGitHubBackfill(
                            repositories: repositories,
                            owners: owners,
                            login: login.isEmpty ? nil : login
                        )
                    }
                }
        }
        .defaultSize(width: 1150, height: 720)

        Settings {
            SettingsView()
                .environment(preferencesStore)
                .environment(\.authService, authService)
                .environment(triageStore)
        }
    }

    // MARK: - Composition Root Wiring

    private func setupServicesAndSync() {
        triageStore.authService = authService

        // 1. Initialize Gmail Service
        let gmailService = GmailService(authService: authService)
        triageStore.gmailService = gmailService

        // 2. Initialize GitHub Service with token provider fallback
        let gitHubService = GitHubService {
            // First inspect preferences store in-memory cache
            let prefToken = await preferencesStore.githubPAT.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefToken.isEmpty {
                return prefToken
            }
            // Second inspect macOS Keychain
            if let keychainToken = try? await authService.readKeychainValue(key: AuthService.gitHubPATKey) {
                return keychainToken
            }
            throw GitHubError.missingToken
        }
        triageStore.githubService = gitHubService

        // 3. Load disk snapshot immediately for sub-50ms cold start
        triageStore.loadSnapshot()

        // 4. Initialize and start the background sync coordinator
        let coordinator = SyncCoordinator(
            gmailService: gmailService,
            gitHubService: gitHubService
        )
        self.syncCoordinator = coordinator

        Task {
            await coordinator.setOnItemsUpdated { [weak triageStore] items, source in
                Task { @MainActor in
                    triageStore?.setItems(items, for: source)
                }
            }
            await coordinator.setOnBackfillUpdated { [weak triageStore] items in
                Task { @MainActor in
                    triageStore?.setGitHubBackfill(items)
                }
            }
            await coordinator.setBackfillConfiguration(
                repositories: preferencesStore.normalizedTrackedRepositories,
                owners: preferencesStore.normalizedTrackedOwners,
                login: preferencesStore.githubUsername.isEmpty ? nil : preferencesStore.githubUsername
            )
            await coordinator.start()
        }
    }
}
