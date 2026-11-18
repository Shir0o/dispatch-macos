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
    @State private var googleWarning: String? = nil
    @State private var gitHubWarning: String? = nil
    @State private var errorMessage: String? = nil
    @State private var didLoadStoredConnections = false
    @State private var isGoogleSetupExpanded = false

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

            updatesTab
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 560, height: 600)
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
            googleSection

            gitHubSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            guard !didLoadStoredConnections else { return }
            didLoadStoredConnections = true
            await loadStoredConnections()
        }
    }

    // MARK: - Google

    @ViewBuilder
    private var googleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Google Gmail")
                        .font(.headline)

                    Spacer()

                    connectionBadge(
                        isConnected: preferencesStore.isGoogleConnected,
                        connectedLabel: "Connected",
                        disconnectedLabel: "Not connected"
                    )
                }

                if preferencesStore.isGoogleConnected {
                    Text(signedInGoogleText)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Dispatch renews the Gmail token automatically. You stay signed in until you sign out or Google revokes the grant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button("Sign Out") {
                            Task { await signOutGoogle() }
                        }

                        Button("Check Connection") {
                            Task { await verifyGoogleConnection(reportSuccess: true) }
                        }
                        .disabled(isSigningInGoogle)
                    }
                } else {
                    Text("Paste the client ID from an OAuth client of type **iOS**. The Gmail API must be enabled for that project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Google Client ID:", text: Bindable(preferencesStore).googleClientId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    HStack(spacing: 8) {
                        Text(derivedRedirectURI ?? "com.googleusercontent.apps.<client-id>:/oauth2redirect")
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        if let redirect = derivedRedirectURI {
                            Button("Copy Redirect URI") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(redirect, forType: .string)
                                googleStatus = "Redirect URI copied."
                            }
                            .controlSize(.mini)
                        }
                    }

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
                        .disabled(
                            preferencesStore.googleClientId
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty || isSigningInGoogle
                        )
                    }

                    DisclosureGroup(isExpanded: $isGoogleSetupExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Open Google Cloud Console → APIs & Services → Credentials and create an OAuth client ID of type **iOS** (not Web or Desktop).")
                                .fixedSize(horizontal: false, vertical: true)
                            Link(
                                "Open Google Cloud Credentials",
                                destination: URL(string: "https://console.cloud.google.com/apis/credentials")!
                            )

                            Text("2. Enable the Gmail API for the project.")
                            Link(
                                "Open Gmail API",
                                destination: URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!
                            )

                            Text("3. On the OAuth consent screen, add the Gmail address you use with Dispatch under **Test users**.")
                                .fixedSize(horizontal: false, vertical: true)

                            Text("4. Copy the client ID, paste it above, and sign in.")
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Google limits apps in Testing mode: refresh tokens expire after 7 days, so you will sign in again weekly. Publish the consent screen to avoid that.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                        .padding(.top, 4)
                    } label: {
                        Text("How to create the client ID")
                            .font(.caption.weight(.semibold))
                    }
                }

                if let googleStatus {
                    Text(googleStatus)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let googleWarning {
                    Label(googleWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Remove Stale Keychain Item") {
                        Task { await clearStaleGoogleCredential() }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var signedInGoogleText: String {
        let email = preferencesStore.googleAccountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? "Signed in to Gmail." : "Signed in as \(email)."
    }

    // MARK: - GitHub

    @ViewBuilder
    private var gitHubSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("GitHub Open Work")
                        .font(.headline)

                    Spacer()

                    connectionBadge(
                        isConnected: preferencesStore.isGitHubConfigured,
                        connectedLabel: preferencesStore.githubUsername.isEmpty
                            ? "Token saved"
                            : "@\(preferencesStore.githubUsername)",
                        disconnectedLabel: "Not connected"
                    )
                }

                if preferencesStore.isGitHubConfigured {
                    Text("The token is stored in your macOS Keychain and is reused after relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SecureField("GitHub Personal Access Token:", text: $tempGitHubPAT)
                    .textFieldStyle(.roundedBorder)

                Text("Create a **classic** token with the `repo` scope:")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                Link(
                    "Open GitHub token settings",
                    destination: URL(string: "https://github.com/settings/tokens/new")!
                )
                .font(.caption)

                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Note: `Dispatch`  ·  Expiration: your choice")
                    Text("2. Scopes: tick **repo** (full control of private repositories)")
                    Text("3. Click **Generate token**, copy the `ghp_…` value")
                    Text("4. Paste it above and click **Validate & Save Token**")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("`repo` is required: Open Work searches your issues and pull requests, including private repositories. A fine-grained token or the narrower `public_repo` scope will miss private work.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
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
                    .disabled(
                        tempGitHubPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isValidatingGitHub
                    )

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
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let gitHubWarning {
                    Label(gitHubWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Remove Stale Keychain Item") {
                        Task { await clearStaleGitHubCredential() }
                    }
                    .controlSize(.small)
                }

                Text(openWorkScopeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func connectionBadge(
        isConnected: Bool,
        connectedLabel: String,
        disconnectedLabel: String
    ) -> some View {
        Text(isConnected ? connectedLabel : disconnectedLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (isConnected ? Color.green : Color.secondary).opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(isConnected ? Color.green : Color.secondary)
    }

    // MARK: - Stored Connection State

    private func loadStoredConnections() async {
        switch AuthService.gitHubCredentialAvailability() {
        case .available:
            preferencesStore.isGitHubConfigured = true
            openWorkStore.isConfigured = true
            if !preferencesStore.githubUsername.isEmpty {
                gitHubStatus = "Connected as @\(preferencesStore.githubUsername)."
            }
        case .inaccessible(let message):
            preferencesStore.isGitHubConfigured = false
            openWorkStore.isConfigured = false
            gitHubWarning = "A GitHub token is stored, but this build can't read it. \(message)"
        case .missing:
            preferencesStore.isGitHubConfigured = false
        }

        switch AuthService.googleCredentialAvailability() {
        case .available:
            preferencesStore.isGoogleConnected = true
            if preferencesStore.googleAccountEmail.isEmpty {
                await verifyGoogleConnection(reportSuccess: false)
            } else {
                googleStatus = signedInGoogleText
            }
        case .inaccessible(let message):
            preferencesStore.isGoogleConnected = false
            googleWarning = "A Google sign-in is stored, but this build can't read it. \(message)"
        case .missing:
            preferencesStore.isGoogleConnected = false
        }
    }

    /// Renews the Google grant and reads the Gmail profile so Settings can show
    /// the real account instead of an empty form.
    private func verifyGoogleConnection(reportSuccess: Bool) async {
        let clientId = preferencesStore.googleClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else {
            googleWarning = "Add the Google Client ID you used at sign-in, then check the connection."
            return
        }

        do {
            let credential = try await authService.refreshGoogleCredential(clientId: clientId)
            guard let accessToken = credential.accessToken else {
                throw AuthError.missingAccessToken
            }

            let gmail = GmailService(session: .shared) { _ in accessToken }
            let profile = try await gmail.getProfile()
            preferencesStore.googleAccountEmail = profile.emailAddress
            preferencesStore.isGoogleConnected = true
            googleWarning = nil
            googleStatus = "Signed in as \(profile.emailAddress)."
        } catch {
            preferencesStore.isGoogleConnected = false
            googleWarning = "Gmail sign-in is no longer valid: \(error.localizedDescription)"
            if reportSuccess { errorMessage = nil }
        }
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
        googleWarning = nil
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
            let tokens = try await authService.exchangeGoogleCode(
                code: code,
                clientId: clientId,
                codeVerifier: verifier
            )

            preferencesStore.isGoogleConnected = true
            preferencesStore.googleAccountEmail = ""

            let gmail = GmailService(session: .shared) { _ in tokens.accessToken }
            if let profile = try? await gmail.getProfile() {
                preferencesStore.googleAccountEmail = profile.emailAddress
                googleStatus = "Signed in as \(profile.emailAddress)."
            } else {
                googleStatus = "Signed in to Gmail successfully."
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                errorMessage = "Google Sign-In was cancelled."
            } else {
                errorMessage = googleSignInMessage(for: error)
            }
        }
    }

    private func googleSignInMessage(for error: Error) -> String {
        let description = error.localizedDescription
        if description.contains("redirect_uri_mismatch") {
            return "Google Sign-In failed: the OAuth client is not an iOS client, or its bundle/client ID does not match. Create an iOS client and paste its full client ID."
        }
        if description.contains("access_denied") {
            return "Google Sign-In failed: add your Gmail address under Test users on the OAuth consent screen, then try again."
        }
        if description.contains("invalid_client") {
            return "Google Sign-In failed: the client ID is not valid for an installed app."
        }
        return "Google Sign-In failed: \(description)"
    }

    private func signOutGoogle() async {
        do {
            try await authService.deleteKeychainValue(key: AuthService.googleAccessTokenKey)
            try await authService.deleteKeychainValue(key: AuthService.googleRefreshTokenKey)
            try await authService.deleteKeychainValue(key: AuthService.googleTokenExpiryKey)
            preferencesStore.isGoogleConnected = false
            preferencesStore.googleAccountEmail = ""
            googleStatus = "Signed out of Google."
            googleWarning = nil
        } catch {
            errorMessage = "Failed to sign out: \(error.localizedDescription)"
        }
    }

    private func clearStaleGoogleCredential() async {
        await signOutGoogle()
        googleStatus = "Stale Google credential removed. Sign in again."
    }

    private func validateGitHubPAT() async {
        isValidatingGitHub = true
        errorMessage = nil
        gitHubStatus = nil
        gitHubWarning = nil
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
            tempGitHubPAT = ""

            let scopes = result.scopes.isEmpty ? "none reported" : result.scopes.joined(separator: ", ")
            gitHubStatus = "Connected as @\(result.username) (scopes: \(scopes))."
            if !result.scopes.contains("repo") {
                gitHubWarning = "This token does not report the `repo` scope, so private issues and pull requests will be missing. Create a classic token with `repo` checked."
            }
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
        gitHubStatus = "GitHub token removed."
        gitHubWarning = nil
    }

    private func clearStaleGitHubCredential() async {
        await clearGitHubPAT()
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

    // MARK: - Updates Tab

    private var updatesTab: some View {
        Form {
            Section(header: Text("Software Updates").font(.headline)) {
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

                HStack {
                    Text("Current Version")
                    Spacer()
                    Text("v\(currentVersion) (\(buildNumber))")
                        .foregroundStyle(.secondary)
                }

                Button("Check for Updates Now…") {
                    UpdateController.shared.checkForUpdates()
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }
}
