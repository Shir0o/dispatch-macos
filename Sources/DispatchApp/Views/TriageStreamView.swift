import SwiftUI

/// Virtualized stream list presenting dense triage items with unread indicators,
/// author avatars, relative timestamps, snippets, and workflow badges.
public struct TriageStreamView: View {
    @Environment(TriageStore.self) private var store

    public init() {}

    public var body: some View {
        @Bindable var bindableStore = store

        Group {
            if bindableStore.activeItems.isEmpty {
                emptyStateView
            } else {
                List(selection: $bindableStore.selectedItemId) {
                    ForEach(bindableStore.activeItems) { item in
                        TriageStreamRow(item: item)
                            .tag(item.id)
                            .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        .navigationTitle(streamTitle)
    }

    private var streamTitle: String {
        "Gmail Inbox"
    }

    /// Gmail-only after workspace routing. Open Work has its own empty states.
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "envelope.open")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.green)

            Text("Inbox Zero")
                .font(.headline)

            Text("No unread messages in your Gmail inbox.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Stream Item Row

private struct TriageStreamRow: View {
    let item: TriageItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread dot indicator
            Circle()
                .fill(item.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            // Author Avatar or initials
            avatarView

            // Content Column
            VStack(alignment: .leading, spacing: 3) {
                // Top row: Author & Relative Time
                HStack(spacing: 6) {
                    Text(item.authorName)
                        .font(.system(size: 13, weight: item.isUnread ? .bold : .semibold))
                        .lineLimit(1)

                    Spacer()

                    if item.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }

                    Text(item.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Title
                Text(item.title)
                    .font(.system(size: 13, weight: item.isUnread ? .semibold : .regular))
                    .foregroundStyle(item.isUnread ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                // Snippet
                Text(snippetText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Badges row
                badgesView
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatarURL = item.authorAvatarURL {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                default:
                    fallbackInitialsAvatar
                }
            }
        } else {
            fallbackInitialsAvatar
        }
    }

    private var fallbackInitialsAvatar: some View {
        let initial = item.authorName.first.map { String($0).uppercased() } ?? "?"
        return ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 24, height: 24)
            Text(initial)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private var snippetText: String {
        switch item.kind {
        case .email(_, let snippet, _):
            return snippet.isEmpty ? "No preview available" : snippet
        }
    }

    @ViewBuilder
    private var badgesView: some View {
        HStack(spacing: 4) {
            switch item.kind {
            case .email(_, _, let hasHtml):
                if hasHtml {
                    pillView(text: "HTML", color: .secondary)
                }
                if !item.tags.isEmpty {
                    ForEach(item.tags.prefix(2), id: \.self) { tag in
                        pillView(text: tag, color: .secondary)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func pillView(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(color)
    }
}
