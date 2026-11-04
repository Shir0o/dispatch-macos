import SwiftUI

/// Onboarding card presented when neither Google nor GitHub accounts are connected.
public struct OnboardingView: View {
    @Environment(PreferencesStore.self) private var preferencesStore
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Header Icon & Title
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .shadow(color: Color.blue.opacity(0.35), radius: 12, x: 0, y: 6)

                    Image(systemName: "tray.2.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("Welcome to Dispatch")
                    .font(.system(size: 24, weight: .bold))

                Text("Sub-50ms native inbox & GitHub triage client with 1-click local coding agent dispatch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            // Connection Guides
            HStack(spacing: 16) {
                accountCard(
                    title: "Gmail Inbox",
                    icon: "envelope.fill",
                    iconColor: .red,
                    description: "Connect via Google Cloud OAuth with PKCE and sandboxed reverse-DNS redirect.",
                    actionTitle: "Configure Gmail",
                    isConnected: !preferencesStore.googleClientId.isEmpty
                )

                accountCard(
                    title: "GitHub Notifications",
                    icon: "chevron.left.forwardslash.chevron.right",
                    iconColor: .purple,
                    description: "Add a Personal Access Token with repo & notifications scopes.",
                    actionTitle: "Configure GitHub",
                    isConnected: !preferencesStore.githubPAT.isEmpty
                )
            }
            .frame(maxWidth: 580)

            // Preferences Button
            Button {
                openSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                    Text("Open Preferences")
                }
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            // Security note
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                Text("Tokens and credentials reside strictly in your macOS Keychain.")
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func accountCard(
        title: String,
        icon: String,
        iconColor: Color,
        description: String,
        actionTitle: String,
        isConnected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(.headline)

                Spacer()

                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button {
                openSettings()
            } label: {
                Text(isConnected ? "Connected" : actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isConnected)
        }
        .padding(16)
        .frame(height: 160)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}
