import SwiftUI
import AppKit
import AuthenticationServices

private struct AuthServiceKey: EnvironmentKey {
    static let defaultValue: AuthService = AuthService()
}

extension EnvironmentValues {
    public var authService: AuthService {
        get { self[AuthServiceKey.self] }
        set { self[AuthServiceKey.self] = newValue }
    }
}

/// macOS preferences window managing Google and GitHub credentials and
/// local coding agent dispatch configuration.
public struct SettingsView: View {
    @Environment(PreferencesStore.self) private var preferencesStore
    @Environment(OpenWorkStore.self) private var openWorkStore
    @Environment(\.authService) private var authService

    @State private var tempGitHubPAT: String = ""
    @State private var isSigningInGoogle: Bool = false
    @State private var isValidatingGitHub: Bool = false
    @State private var isShowingClearConfirmation: Bool = false
    @State private var googleStatus: String? = nil
    @State private var gitHubStatus: String? = nil
    @State private var errorMessage: String? = nil

    public init() {}

    /// Redirect URI Google expects for the client ID currently entered above.
    private var derivedRedirectURI: String? {
        try? AuthService.googleRedirect(for: preferencesStore.googleClientId).redirectURI
    }

    public var body: some View {
        TabView {
            accountsTab
                .tabItem {
                    Label("Accounts", systemImage: "person.crop.circle")
                }

            agentDispatchTab
                .tabItem {
                    Label("Agent Dispatch", systemImage: "sparkles")
                }
        }
        .frame(width: 540, height: 520)
        .padding(20)
        .alert("Clear GitHub PAT?", isPresented: $isShowingClearConfirmation) {
            Button("Clear PAT", role: .destructive) {
                Task { await clearGitHubPAT() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Open Work will disconnect and must fetch again after you save a token. Hidden items stay hidden.")
        }
    }

    // MARK: - Accounts Tab

    private var accountsTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Google Gmail OAuth")
                        .font(.headline)

                    TextField("Google Client ID:", text: Bindable(preferencesStore).googleClientId)
                        .textFieldStyle(.roundedBorder)

                    Text("Create an OAuth client ID of type **iOS** in Google Cloud Console (not Web or Desktop), enable the Gmail API, and add yourself as a test user. Google derives the redirect URI from that client ID:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(derivedRedirectURI ?? "com.googleusercontent.apps.<client-id>:/oauth2redirect")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            Task { await signInWithGoogle() }
                        } label: {
                            if isSigningInGoogle {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Sign In with Google")
                            }
                        }
                        .disabled(preferencesStore.googleClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSigningInGoogle)

                        Button("Sign Out") {
                            Task { await signOutGoogle() }
                        }
                    }

                    if let googleStatus {
                        Text(googleStatus)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
                .padding(.vertical, 6)

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitHub Personal Access Token")
                        .font(.headline)

                    SecureField("GitHub PAT:", text: $tempGitHubPAT)
                        .textFieldStyle(.roundedBorder)

                    Text("Generate a Classic Personal Access Token on GitHub with this scope:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("• repo")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            Task { await validateGitHubPAT() }
                        } label: {
                            if isValidatingGitHub {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Validate & Save Token")
                            }
                        }
                        .disabled(tempGitHubPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingGitHub)

                        if preferencesStore.isGitHubConfigured {
                            Button("Clear PAT") {
                                isShowingClearConfirmation = true
                            }
                        }
                    }

                    if let gitHubStatus {
                        Text(gitHubStatus)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Text(openWorkScopeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Agent Dispatch Tab

    private var agentDispatchTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Local Projects Directory")
                        .font(.headline)

                    HStack {
                        TextField("Path:", text: Bindable(preferencesStore).projectsDirectory)
                            .textFieldStyle(.roundedBorder)

                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.prompt = "Choose"
                            // A sandboxed app that is not frontmost opens the panel
                            // behind every other window, which reads as "nothing happened".
                            NSApp.activate(ignoringOtherApps: true)
                            panel.begin { response in
                                let selectedURL = panel.url
                                Task { @MainActor in
                                    guard response == .OK, let selectedURL else { return }
                                    preferencesStore.projectsDirectory = selectedURL.path
                                }
                            }
                        }
                    }

                    Text("Dispatch inspects this directory to link local repository working copies inside formatted prompts for CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Coding Agent")
                        .font(.headline)

                    Picker("Agent:", selection: Bindable(preferencesStore).preferredAgent) {
                        ForEach(AgentCLI.allCases) { agent in
                            Text(agent.rawValue).tag(agent)
                        }
                    }
                    .pickerStyle(.menu)

                    if preferencesStore.preferredAgent != .none {
                        TextField("Command:", text: Bindable(preferencesStore).agentCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Text("⌘⇧A stages the issue prompt to a file and copies a ready-to-run command such as `opencode run \"$(cat …)\"` for you to paste into the terminal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("⌘⇧A copies the raw issue prompt to the clipboard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Preferred Terminal / IDE")
                        .font(.headline)

                    Picker("Terminal App:", selection: Bindable(preferencesStore).preferredTerminal) {
                        ForEach(TerminalApp.allCases) { app in
                            Text(app.rawValue).tag(app)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Activated automatically via NSWorkspace after copying prompt context to NSPasteboard.general.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workflow Shortcut")
                        .font(.subheadline.weight(.semibold))

                    Text("Press ⌘⇧A on any selected GitHub issue or pull request to assemble the prompt, write to clipboard, and bring your terminal into focus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private var openWorkScopeText: String {
        let subject = preferencesStore.githubUsername.isEmpty
            ? "you"
            : "@\(preferencesStore.githubUsername)"
        return "Open Work shows open issues and pull requests involving \(subject) that this token can read: authored, assigned, mentioned, or commented on. Review requests and subscriptions are not included."
    }

    private func signInWithGoogle() async {
        isSigningInGoogle = true
        errorMessage = nil
        googleStatus = nil
        defer { isSigningInGoogle = false }

        let clientId = preferencesStore.googleClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else {
            errorMessage = "Please enter a valid Google Client ID first."
            return
        }

        do {
            let code = try await authService.startGoogleOAuth(clientId: clientId)
            guard let verifier = await authService.activeCodeVerifier else {
                throw AuthError.missingAuthorizationCode
            }
            _ = try await authService.exchangeGoogleCode(
                code: code,
                clientId: clientId,
                codeVerifier: verifier
            )
            googleStatus = "Signed in to Gmail successfully!"
        } catch {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                errorMessage = "Google Sign-In was cancelled."
            } else {
                errorMessage = "Google Sign-In failed: \(error.localizedDescription)"
            }
        }
    }

    private func signOutGoogle() async {
        do {
            try await authService.deleteKeychainValue(key: AuthService.googleAccessTokenKey)
            try await authService.deleteKeychainValue(key: AuthService.googleRefreshTokenKey)
            try await authService.deleteKeychainValue(key: AuthService.googleTokenExpiryKey)
            googleStatus = "Signed out of Google."
        } catch {
            errorMessage = "Failed to sign out: \(error.localizedDescription)"
        }
    }

    private func validateGitHubPAT() async {
        isValidatingGitHub = true
        errorMessage = nil
        gitHubStatus = nil
        defer { isValidatingGitHub = false }

        let token = tempGitHubPAT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Please enter a GitHub PAT."
            return
        }

        do {
            let result = try await authService.validateGitHubPAT(token: token)
            preferencesStore.githubUsername = result.username
            preferencesStore.isGitHubConfigured = true
            openWorkStore.isConfigured = true
            gitHubStatus = "Connected as @\(result.username) (Scopes: \(result.scopes.joined(separator: ", ")))"
            Task { await openWorkStore.refresh() }
        } catch {
            errorMessage = "GitHub PAT validation failed: \(error.localizedDescription)"
        }
    }

    private func clearGitHubPAT() async {
        do {
            try await authService.deleteKeychainValue(key: AuthService.gitHubPATKey)
        } catch {
            errorMessage = "Failed to clear GitHub token: \(error.localizedDescription)"
            return
        }

        UserDefaults.standard.removeObject(forKey: LegacyStateMigrator.legacyPATKey)
        preferencesStore.isGitHubConfigured = false
        openWorkStore.isConfigured = false
        openWorkStore.clear()
        tempGitHubPAT = ""
        gitHubStatus = "GitHub token removed"
    }
}
