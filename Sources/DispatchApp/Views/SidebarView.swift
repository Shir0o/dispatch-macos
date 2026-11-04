import SwiftUI

/// Primary navigation sidebar providing workspace selection, GitHub smart filters,
/// and live sync status.
public struct SidebarView: View {
    @Environment(TriageStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Workspaces") {
                    workspaceRow(
                        title: "Gmail",
                        icon: "envelope.fill",
                        iconColor: .red,
                        source: .gmail,
                        unreadCount: store.unreadCount(for: .gmail)
                    )

                    workspaceRow(
                        title: "GitHub",
                        icon: "chevron.left.forwardslash.chevron.right",
                        iconColor: .purple,
                        source: .gitHub,
                        unreadCount: store.unreadCount(for: .gitHub)
                    )
                }

                if store.activeWorkspace == .gitHub {
                    Section("GitHub Filters") {
                        ForEach(GitHubFilter.allCases) { filter in
                            Button {
                                store.gitHubFilter = filter
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: filter.iconName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(filterColor(for: filter))
                                        .frame(width: 18)

                                    Text(filter.rawValue)
                                        .font(.system(.body, design: .default))
                                        .foregroundStyle(store.gitHubFilter == filter ? Color.primary : Color.secondary)

                                    Spacer()

                                    let count = filterCount(for: filter)
                                    if count > 0 {
                                        Text("\(count)")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                store.gitHubFilter == filter
                                                    ? Color.accentColor.opacity(0.18)
                                                    : Color.secondary.opacity(0.15),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(
                                                store.gitHubFilter == filter
                                                    ? Color.accentColor
                                                    : Color.secondary
                                            )
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(
                                    store.gitHubFilter == filter
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom Status Bar
            HStack(spacing: 8) {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("Live")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

    // MARK: - Subviews

    @ViewBuilder
    private func workspaceRow(
        title: String,
        icon: String,
        iconColor: Color,
        source: TriageSource,
        unreadCount: Int
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

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                            in: Capsule()
                        )
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
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

    private func filterColor(for filter: GitHubFilter) -> Color {
        switch filter {
        case .all:
            return .secondary
        case .ciAlerts:
            return .orange
        case .mentions:
            return .purple
        case .reviewRequests:
            return .blue
        }
    }

    private func filterCount(for filter: GitHubFilter) -> Int {
        switch filter {
        case .all:
            return store.gitHubItems.count
        case .ciAlerts:
            return store.gitHubItems.filter { item in
                item.tags.contains("ci_activity") ||
                {
                    if case .gitHubPullRequest(_, _, _, _, let ci) = item.kind {
                        return ci == .completedFailure || ci == .queued || ci == .inProgress
                    }
                    return false
                }()
            }.count
        case .mentions:
            return store.gitHubItems.filter { $0.tags.contains("mention") || $0.tags.contains("team_mention") }.count
        case .reviewRequests:
            return store.gitHubItems.filter { item in
                item.tags.contains("review_requested") ||
                {
                    if case .gitHubPullRequest(_, _, _, let r, _) = item.kind {
                        return r == .pending || r == .changesRequested
                    }
                    return false
                }()
            }.count
        }
    }
}
