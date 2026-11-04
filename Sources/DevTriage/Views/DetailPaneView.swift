import SwiftUI
import AppKit

/// Detail inspector displaying email content via recycled sandboxed WebKit or
/// GitHub issue/PR metadata with local coding agent dispatch and comment timeline.
public struct DetailPaneView: View {
    @Environment(TriageStore.self) private var store
    @Environment(PreferencesStore.self) private var preferencesStore

    @State private var emailHtmlBody: String? = nil
    @State private var isFetchingEmailDetail: Bool = false
    @State private var loadRemoteImages: Bool = false

    @State private var gitHubDetail: GitHubIssueDetail? = nil
    @State private var isFetchingGitHubDetail: Bool = false
    @State private var detailError: String? = nil

    public init() {}

    public var body: some View {
        ZStack {
            if let item = store.selectedItem {
                detailContent(for: item)
                    .id(item.id)
            } else {
                emptySelectionView
            }

            // Transient floating toast banner
            if store.isToastVisible, let message = store.toastMessage {
                toastOverlay(message: message)
            }
        }
        .frame(minWidth: 400, idealWidth: 600)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptySelectionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Item Selected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Select an item from the triage stream to inspect details.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Detail Router

    @ViewBuilder
    private func detailContent(for item: TriageItem) -> some View {
        switch item.source {
        case .gmail:
            emailDetailView(item: item)
        case .gitHub:
            gitHubDetailView(item: item)
        }
    }

    // MARK: - Gmail Detail View

    @ViewBuilder
    private func emailDetailView(item: TriageItem) -> some View {
        VStack(spacing: 0) {
            // Email Header Bar
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                            .textSelection(.enabled)

                        HStack(spacing: 6) {
                            Text("From:")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(item.authorName)
                                .font(.caption.weight(.semibold))
                                .textSelection(.enabled)
                            Spacer()
                            Text(item.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Action buttons
                    HStack(spacing: 6) {
                        Button {
                            loadRemoteImages.toggle()
                        } label: {
                            Label(
                                loadRemoteImages ? "Hide Images" : "Load Images",
                                systemImage: loadRemoteImages ? "photo.fill" : "photo"
                            )
                        }
                        .controlSize(.small)
                        .help("Toggle remote image loading (relax CSP)")

                        Button {
                            store.archive(item: item)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .controlSize(.small)
                        .help("Archive thread (e)")

                        Button {
                            store.star(item: item)
                        } label: {
                            Image(systemName: item.isStarred ? "star.fill" : "star")
                                .foregroundStyle(item.isStarred ? .yellow : .primary)
                        }
                        .controlSize(.small)
                        .help("Star thread (s)")

                        Button {
                            store.trash(item: item)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .help("Trash thread (#)")

                        Button {
                            NSWorkspace.shared.open(item.webURL)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .controlSize(.small)
                        .help("Open in Gmail Web (⌘O)")
                    }
                }
            }
            .padding(16)
            .background(.bar)

            Divider()

            // Email Body
            if isFetchingEmailDetail {
                VStack {
                    Spacer()
                    ProgressView("Loading message...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RecycledWKWebView(
                    htmlContent: emailHtmlBody ?? itemSnippetFallback(item: item),
                    loadRemoteImages: loadRemoteImages
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            await loadEmailDetails(threadId: item.id)
        }
    }

    private func itemSnippetFallback(item: TriageItem) -> String {
        if case .email(_, let snippet, _) = item.kind {
            return "<p>\(snippet)</p>"
        }
        return "<p>\(item.title)</p>"
    }

    private func loadEmailDetails(threadId: String) async {
        isFetchingEmailDetail = true
        loadRemoteImages = false
        emailHtmlBody = nil

        defer { isFetchingEmailDetail = false }

        guard let gmailService = store.gmailService else {
            return
        }

        do {
            let details = try await gmailService.fetchThreadDetails(threadId: threadId)
            self.emailHtmlBody = details.htmlBody ?? "<p>\(details.snippet)</p>"
        } catch {
            self.detailError = error.localizedDescription
            self.emailHtmlBody = "<p style='color:red;'>Failed to load thread details: \(error.localizedDescription)</p>"
        }
    }

    // MARK: - GitHub Detail View

    @ViewBuilder
    private func gitHubDetailView(item: TriageItem) -> some View {
        VStack(spacing: 0) {
            // Top Action Bar
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                            .textSelection(.enabled)

                        HStack(spacing: 8) {
                            Text(item.authorName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(item.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            statusPills(for: item)
                        }
                    }

                    Spacer()

                    // Action Controls
                    HStack(spacing: 8) {
                        Button {
                            dispatchToAgent(item: item)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.purple)
                                Text("Dispatch to Agent")
                                    .fontWeight(.medium)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        .help("Format prompt to clipboard & activate terminal (⌘⇧A)")

                        Button {
                            store.archive(item: item)
                        } label: {
                            Label("Dismiss", systemImage: "checkmark")
                        }
                        .controlSize(.small)
                        .help("Dismiss notification (e)")

                        Button {
                            store.trash(item: item)
                        } label: {
                            Image(systemName: "bell.slash")
                        }
                        .controlSize(.small)
                        .help("Unsubscribe from notification (#)")

                        Button {
                            NSWorkspace.shared.open(item.webURL)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .controlSize(.small)
                        .help("Open on GitHub (⌘O)")
                    }
                }
            }
            .padding(16)
            .background(.bar)

            Divider()

            // Issue Body & Comments Timeline
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isFetchingGitHubDetail {
                        HStack {
                            Spacer()
                            ProgressView("Loading issue context...")
                            Spacer()
                        }
                        .padding(.top, 40)
                    } else if let detail = gitHubDetail {
                        // Issue Description
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Description")
                                    .font(.headline)
                                Spacer()
                                Text("Opened by @\(detail.author)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Divider()

                            Text(LocalizedStringKey(detail.body.isEmpty ? "*No description provided.*" : detail.body))
                                .font(.system(.body, design: .default))
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        // Comments Section
                        if !detail.comments.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Timeline Comments (\(detail.comments.count))")
                                    .font(.headline)

                                ForEach(detail.comments, id: \.id) { comment in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("@\(comment.author)")
                                                .font(.caption.weight(.bold))
                                            Spacer()
                                            Text(comment.createdAt, style: .relative)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }

                                        Divider()

                                        Text(LocalizedStringKey(comment.body))
                                            .font(.system(.body, design: .default))
                                            .textSelection(.enabled)
                                    }
                                    .padding(12)
                                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    } else {
                        // Fallback summary
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary")
                                .font(.headline)
                            Text(item.title)
                                .font(.body)
                                .textSelection(.enabled)
                            if !item.tags.isEmpty {
                                Text("Tags: \(item.tags.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                }
                .padding(20)
            }
        }
        .task(id: item.id) {
            await loadGitHubDetails(item: item)
        }
    }

    @ViewBuilder
    private func statusPills(for item: TriageItem) -> some View {
        switch item.kind {
        case .gitHubIssue(_, _, let state, _):
            pillBadge(
                text: state.capitalized,
                color: state.lowercased() == "closed" ? .purple : .green
            )
        case .gitHubPullRequest(_, _, let isDraft, let review, let ci):
            if isDraft {
                pillBadge(text: "Draft", color: .secondary)
            }
            if review != .none {
                pillBadge(text: review == .approved ? "Approved" : "Review Pending", color: review == .approved ? .green : .yellow)
            }
            if ci != .neutral {
                pillBadge(text: ci == .completedSuccess ? "CI Passed" : "CI Alert", color: ci == .completedSuccess ? .green : .red)
            }
        default:
            EmptyView()
        }
    }

    private func pillBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(color)
    }

    private func loadGitHubDetails(item: TriageItem) async {
        isFetchingGitHubDetail = true
        gitHubDetail = nil
        defer { isFetchingGitHubDetail = false }

        let repo: String
        let number: Int
        switch item.kind {
        case .gitHubIssue(let n, let r, _, _):
            number = n
            repo = r
        case .gitHubPullRequest(let n, let r, _, _, _):
            number = n
            repo = r
        default:
            return
        }

        guard let githubService = store.githubService else { return }

        do {
            self.gitHubDetail = try await githubService.fetchIssueDetails(repo: repo, number: number)
        } catch {
            self.detailError = error.localizedDescription
        }
    }

    // MARK: - Agent Dispatch Execution

    private func dispatchToAgent(item: TriageItem) {
        let repo: String
        let number: Int
        switch item.kind {
        case .gitHubIssue(let n, let r, _, _):
            number = n
            repo = r
        case .gitHubPullRequest(let n, let r, _, _, _):
            number = n
            repo = r
        default:
            store.showToast("Cannot dispatch non-issue item")
            return
        }

        let localPath = preferencesStore.localPath(for: repo)
        let payload = AgentDispatchPayload(
            issueNumber: number,
            repository: repo,
            title: item.title,
            body: gitHubDetail?.body ?? item.title,
            comments: gitHubDetail?.comments ?? [],
            localRepoPath: localPath
        )

        Task {
            do {
                try await AgentDispatchService().dispatch(
                    payload: payload,
                    preferredTerminal: preferencesStore.preferredTerminal
                )
                store.showToast("Copied issue context to clipboard")
            } catch {
                store.showToast("Dispatch error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Toast View

    @ViewBuilder
    private func toastOverlay(message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.isToastVisible)
    }
}
