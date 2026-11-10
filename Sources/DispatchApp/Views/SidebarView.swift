import SwiftUI

/// Primary navigation sidebar providing workspace selection, Gmail unread
/// counts, and the neutral Open Work item count.
public struct SidebarView: View {
    @Environment(TriageStore.self) private var store
    @Environment(OpenWorkStore.self) private var openWorkStore
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Workspaces") {
                    let gmailUnread = store.unreadCount(for: .gmail)
                    workspaceRow(
                        title: "Gmail",
                        icon: "envelope.fill",
                        iconColor: .red,
                        source: .gmail,
                        badge: gmailUnread > 0 ? "\(gmailUnread)" : nil,
                        badgeIsUnread: true
                    )

                    workspaceRow(
                        title: "GitHub",
                        icon: "chevron.left.forwardslash.chevron.right",
                        iconColor: .purple,
                        source: .gitHub,
                        badge: openWorkBadge,
                        badgeIsUnread: false
                    )
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom status bar. The GitHub refresh state lives in Open Work.
            HStack(spacing: 8) {
                Spacer()

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Preferences (⌘,)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
    }

    // MARK: - Open Work Badge

    /// A neutral count once work is loaded and visible; otherwise an em dash.
    private var openWorkBadge: String {
        let isLoaded = openWorkStore.status.phase == .ready || !openWorkStore.allItems.isEmpty
        guard isLoaded, openWorkStore.visibleCount > 0 else { return "—" }
        let count = openWorkStore.visibleCount
        return "\(count) open item\(count == 1 ? "" : "s")"
    }

    // MARK: - Subviews

    @ViewBuilder
    private func workspaceRow(
        title: String,
        icon: String,
        iconColor: Color,
        source: TriageSource,
        badge: String?,
        badgeIsUnread: Bool
    ) -> some View {
        let isSelected = store.activeWorkspace == source

        Button {
            store.activeWorkspace = source
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                Text(title)
                    .font(.system(.body, design: .default, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            badgeBackground(isSelected: isSelected, badgeIsUnread: badgeIsUnread),
                            in: Capsule()
                        )
                        .foregroundStyle(
                            badgeForeground(isSelected: isSelected, badgeIsUnread: badgeIsUnread)
                        )
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func badgeBackground(isSelected: Bool, badgeIsUnread: Bool) -> Color {
        if badgeIsUnread {
            return isSelected ? Color.accentColor : Color.secondary.opacity(0.2)
        }
        return Color.secondary.opacity(0.15)
    }

    private func badgeForeground(isSelected: Bool, badgeIsUnread: Bool) -> Color {
        if badgeIsUnread {
            return isSelected ? Color.white : Color.primary
        }
        return Color.secondary
    }
}
