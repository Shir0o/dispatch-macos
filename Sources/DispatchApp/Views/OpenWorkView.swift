import SwiftUI
import AppKit

/// The GitHub workspace: open issues and pull requests involving the
/// authenticated user, grouped by repository, with local hide and undo.
///
/// Every piece of copy comes from `OpenWorkPresentation`; this view adds layout,
/// row actions, the info popover and the 6-second undo banner.
public struct OpenWorkView: View {
    @Environment(OpenWorkStore.self) private var openWorkStore
    @Environment(PreferencesStore.self) private var preferencesStore
    @Environment(\.openSettings) private var openSettings

    @State private var isInfoPresented = false

    public init() {}

    public var body: some View {
        @Bindable var bindableStore = openWorkStore

        VStack(spacing: 0) {
            header

            if let truncation = presentation.truncationText {
                truncationLine(truncation)
            }

            if let banner = presentation.bannerText {
                staleBanner(banner)
            }

            Divider()

            listContent(selection: $bindableStore.selectedKey)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        .navigationTitle("Open Work")
        .task {
            await openWorkStore.noteWorkspaceOpened()
        }
        .overlay(alignment: .bottom) {
            if openWorkStore.canUndo, let key = openWorkStore.lastHiddenKey {
                undoBanner(key: key)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: openWorkStore.canUndo)
        .onChange(of: openWorkStore.lastHiddenKey) { _, newKey in
            if let newKey {
                AccessibilityNotification.Announcement("Hidden \(newKey). Press Command-Z to undo.").post()
            }
        }
    }

    // MARK: - Presentation

    private var presentation: OpenWorkPresentation {
        var status = openWorkStore.status
        if !openWorkStore.isConfigured {
            // `clear()` resets status to a fresh idle with no error, so the
            // view maps the connection flag onto the disconnected row.
            status.phase = .idle
            status.error = .notConfigured
        }

        let hasSummary = status.lastSuccess != nil
            || (status.matchedCount > 0 && openWorkStore.allItems.isEmpty)

        return OpenWorkPresentation(
            status: status,
            visibleCount: openWorkStore.visibleCount,
            hiddenCount: openWorkStore.hiddenCount,
            hasSummary: hasSummary,
            now: Date()
        )
    }

    // MARK: - Header

    private var header: some View {
        let presentation = presentation
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.headerText)
                        .font(.headline)
                        .textSelection(.enabled)

                    if !presentation.secondaryText.isEmpty {
                        Text(presentation.secondaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 8)

                headerControls(presentation: presentation)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func headerControls(presentation: OpenWorkPresentation) -> some View {
        HStack(spacing: 8) {
            if openWorkStore.isConfigured, presentation.action.kind != .openSettings {
                if presentation.action.kind == .refresh {
                    Button {
                        perform(action: presentation.action)
                    } label: {
                        Label(presentation.action.label, systemImage: "arrow.clockwise")
                    }
                    .disabled(!presentation.action.isEnabled)
                    .help("Fetch Open Work again")
                } else {
                    Button {
                        Task { await openWorkStore.refresh() }
                    } label: {
                        Label(
                            openWorkStore.status.phase == .running ? "Refreshing…" : "Refresh",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(openWorkStore.status.phase == .running)
                    .help("Fetch Open Work again")

                    Button {
                        perform(action: presentation.action)
                    } label: {
                        Label(
                            presentation.action.label,
                            systemImage: symbol(for: presentation.action.kind)
                        )
                    }
                    .disabled(!presentation.action.isEnabled)
                    .help(actionHelp(for: presentation.action))
                }
            } else {
                Button {
                    perform(action: presentation.action)
                } label: {
                    Label(presentation.action.label, systemImage: "gearshape")
                }
                .disabled(!presentation.action.isEnabled)
            }

            Button {
                isInfoPresented.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("What appears in Open Work")
            .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                Text(scopeSentence)
                    .font(.callout)
                    .frame(width: 320, alignment: .leading)
                    .padding(14)
            }

            hiddenKeysMenu
        }
    }

    private var hiddenKeysMenu: some View {
        Menu {
            Section("Shortcuts") {
                Text("j / k — Move selection")
                Text("e — Hide from Open Work")
                Text("⌘O — Open on GitHub")
                Text("⌘⇧A — Dispatch to agent")
                Text("⌘Z — Undo last hide")
                Text("u, s, # — Not available in Open Work")
            }

            Divider()

            Button("Clear all hidden keys") {
                openWorkStore.clearAllHidden()
            }
            .disabled(openWorkStore.hiddenKeys.isEmpty)

            Text("Removes every hidden key, including keys not present in the current result.")
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hidden keys and shortcuts")
    }

    // MARK: - Body

    @ViewBuilder
    private func listContent(selection: Binding<String?>) -> some View {
        if openWorkStore.groups.isEmpty {
            emptyState(presentation: presentation)
        } else {
            List(selection: selection) {
                ForEach(openWorkStore.groups, id: \.repository) { group in
                    Section {
                        ForEach(group.items) { item in
                            OpenWorkRow(
                                item: item,
                                onOpen: { NSWorkspace.shared.open(item.webURL) },
                                onHide: { openWorkStore.hide(key: item.key) }
                            )
                            .tag(item.key)
                        }
                    } header: {
                        HStack {
                            Text(group.repository)
                            Spacer()
                            Text("\(group.visibleCount) visible")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func emptyState(presentation: OpenWorkPresentation) -> some View {
        VStack(spacing: 12) {
            Spacer()

            if openWorkStore.status.phase == .running, presentation.emptyText == nil {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Open Work…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let text = presentation.emptyText {
                Image(systemName: emptySymbol(for: presentation))
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.tertiary)

                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Banners

    private func truncationLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    private func staleBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)

            Button(presentation.action.label) {
                perform(action: presentation.action)
            }
            .controlSize(.small)
            .disabled(!presentation.action.isEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private func undoBanner(key: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)

            Text("Hidden \(key).")
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let deadline = openWorkStore.undoDeadline {
                UndoProgressIndicator(deadline: deadline, duration: OpenWorkStore.undoWindow)
            }

            Button("Undo") {
                openWorkStore.unhide(key: key)
            }
            .controlSize(.small)
            .help("Restore this item to Open Work (⌘Z)")

            Button {
                openWorkStore.dismissUndoBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hidden \(key). Press Command-Z to undo.")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
    }

    // MARK: - Actions

    private func perform(action: PresentationAction) {
        guard action.isEnabled else { return }

        switch action.kind {
        case .openSettings, .updateToken:
            openSettings()
        case .refresh:
            Task { await openWorkStore.refresh() }
        case .retry(let until):
            if let until, Date() < until { return }
            Task { await openWorkStore.refresh() }
        case .clearHidden:
            openWorkStore.clearAllHidden()
        }
    }

    private func symbol(for kind: OpenWorkAction) -> String {
        switch kind {
        case .openSettings, .updateToken:
            return "gearshape"
        case .retry:
            return "arrow.clockwise"
        case .refresh:
            return "arrow.clockwise"
        case .clearHidden:
            return "eye.slash"
        }
    }

    private func actionHelp(for action: PresentationAction) -> String {
        switch action.kind {
        case .openSettings:
            return "Open Settings"
        case .updateToken:
            return "Update the GitHub token in Settings"
        case .retry(let until):
            if let until {
                return "Enabled \(until.formatted(date: .omitted, time: .shortened))"
            }
            return "Try the refresh again"
        case .refresh:
            return "Fetch Open Work again"
        case .clearHidden:
            return "Restore every hidden item"
        }
    }

    private func emptySymbol(for presentation: OpenWorkPresentation) -> String {
        if presentation.action.kind == .openSettings {
            return "link.badge.plus"
        }
        if presentation.action.kind == .clearHidden {
            return "eye.slash"
        }
        if openWorkStore.status.error != nil {
            return "exclamationmark.triangle"
        }
        if openWorkStore.status.phase == .ready {
            return "checkmark.circle"
        }
        return "tray"
    }

    private var scopeSentence: String {
        let login = preferencesStore.githubUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = login.isEmpty ? "you" : "@\(login)"
        return "Open work involving \(subject) that this token can read: authored, assigned, "
            + "mentioned, or commented on. Review requests and subscriptions are not included."
    }
}

// MARK: - Row

private struct OpenWorkRow: View {
    let item: OpenWorkItem
    let onOpen: () -> Void
    let onHide: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind == .pullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.kind == .pullRequest ? Color.purple : Color.green)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(item.repository)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)

                    Text("#\(item.number)")
                        .font(.caption2.monospacedDigit())

                    Text("@\(item.authorLogin)")
                        .font(.caption2)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if item.kind == .pullRequest {
                        Text("PR")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.purple)
                    }

                    Text(item.updatedAt, style: .relative)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            Button("Open on GitHub", action: onOpen)
            Button("Hide from Open Work", action: onHide)
        }
    }

    private var accessibilityLabel: String {
        let kind = item.kind == .pullRequest ? "Pull request" : "Issue"
        let date = item.updatedAt.formatted(date: .long, time: .shortened)
        return "\(kind): \(item.title). \(item.repository) number \(item.number). "
            + "Updated by @\(item.authorLogin) on \(date)."
    }
}

// MARK: - Undo Progress Indicator

private struct UndoProgressIndicator: View {
    let deadline: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let fraction = duration > 0 ? remaining / duration : 0

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                    .frame(width: 14, height: 14)

                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(-90))
            }
            .accessibilityHidden(true)
        }
    }
}
