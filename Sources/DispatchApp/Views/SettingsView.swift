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
    @Environment(\.authService) private var authService

    @State private var tempGitHubPAT: String = ""
    @State private var isSigningInGoogle: Bool = false
    @State private var isValidatingGitHub: Bool = false
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
        .frame(width: 540, height: 440)
        .padding(20)
        .onAppear {
            tempGitHubPAT = preferencesStore.githubPAT
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

                    Text("Create an OAuth client ID of type **iOS** in Google Cloud Console (not Web or Desktop). Google derives the redirect URI from that client ID:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

                    Text("Generate a Classic Personal Access Token on GitHub with scopes:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text("• repo")
                            .font(.system(.caption, design: .monospaced))
                        Text("• notifications")
                            .font(.system(.caption, design: .monospaced))
                    }
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

                        if !preferencesStore.githubPAT.isEmpty {
                            Button("Clear PAT") {
                                tempGitHubPAT = ""
                                preferencesStore.githubPAT = ""
                                gitHubStatus = "GitHub token removed"
                                Task {
                                    try? await authService.deleteKeychainValue(key: AuthService.gitHubPATKey)
                                }
                            }
                        }
                    }

                    if let gitHubStatus {
                        Text(gitHubStatus)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Open Work Backfill")
                        .font(.headline)

                    TextField("owner/repo", text: trackedRepositoriesBinding, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)

                    Text("One repository per line. Dispatch loads every open issue and pull request from these repositories at launch. Leave empty to include everything you are involved with.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Backfill Now") {
                            NotificationCenter.default.post(
                                name: .dispatchGitHubBackfillRequested,
                                object: nil
                            )
                        }
                        .disabled(preferencesStore.githubPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if !preferencesStore.githubUsername.isEmpty {
                            Text("@\(preferencesStore.githubUsername)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                preferencesStore.projectsDirectory = url.path
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

    private var trackedRepositoriesBinding: Binding<String> {
        Binding(
            get: { preferencesStore.trackedRepositories.joined(separator: "\n") },
            set: { newValue in
                preferencesStore.trackedRepositories = newValue
                    .split(whereSeparator: { $0 == "\n" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
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
            preferencesStore.githubPAT = token
            preferencesStore.githubUsername = result.username
            gitHubStatus = "Connected as @\(result.username) (Scopes: \(result.scopes.joined(separator: ", ")))"
            NotificationCenter.default.post(
                name: .dispatchGitHubBackfillRequested,
                object: nil
            )
        } catch {
            errorMessage = "GitHub PAT validation failed: \(error.localizedDescription)"
        }
    }
}
