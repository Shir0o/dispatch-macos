import SwiftUI
import AppKit

/// Detail inspector displaying email content via recycled sandboxed WebKit or
/// GitHub issue/PR metadata with local coding agent dispatch and comment timeline.
public struct DetailPaneView: View {
    @Environment(TriageStore.self) private var store
    @Environment(OpenWorkStore.self) private var openWorkStore
    @Environment(PreferencesStore.self) private var preferencesStore

    @State private var emailHtmlBody: String? = nil
    @State private var isFetchingEmailDetail: Bool = false
    @State private var loadRemoteImages: Bool = false

    @State private var detailError: String? = nil

    @State private var openWorkDetail: GitHubIssueDetail? = nil
    @State private var isFetchingOpenWorkDetail: Bool = false
    @State private var openWorkDetailError: String? = nil
    @State private var openWorkDispatchFailureItem: OpenWorkItem?

    public init() {}

    public var body: some View {
        ZStack {
            if store.activeWorkspace == .gitHub, let item = openWorkStore.selectedItem {
                openWorkDetailView(item: item)
                    .id(item.key)
            } else if store.activeWorkspace == .gmail, let item = store.selectedItem {
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
        .alert(
            "Couldn't load issue details",
            isPresented: Binding(
                get: { openWorkDispatchFailureItem != nil },
                set: { if !$0 { openWorkDispatchFailureItem = nil } }
            ),
            presenting: openWorkDispatchFailureItem
        ) { item in
            Button("Send title only") {
                dispatchOpenWorkTitleOnly(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The issue body and comments could not be fetched. Send the title only, or cancel and try again.")
        }
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
        emailDetailView(item: item)
    }

    // MARK: - Open Work Detail View

    @ViewBuilder
    private func openWorkDetailView(item: OpenWorkItem) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                            .textSelection(.enabled)

                        HStack(spacing: 8) {
                            Text("\(item.repository) #\(item.number)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text("@\(item.authorLogin)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("Updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if item.kind == .pullRequest {
                                pillBadge(text: "PR", color: .purple)
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            dispatchOpenWorkItem(item)
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
                            NSWorkspace.shared.open(item.webURL)
                        } label: {
                            Label("Open on GitHub", systemImage: "safari")
                        }
                        .controlSize(.small)
                        .help("Open on GitHub (⌘O)")

                        Button {
                            openWorkStore.hide(key: item.key)
                        } label: {
                            Label("Hide", systemImage: "eye.slash")
                        }
                        .controlSize(.small)
                        .help("Hide from Open Work (e)")
                    }
                }
            }
            .padding(16)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isFetchingOpenWorkDetail {
                        HStack {
                            Spacer()
                            ProgressView("Loading issue context...")
                            Spacer()
                        }
                        .padding(.top, 40)
                    } else if let error = openWorkDetailError {
                        openWorkInlineError(error)
                    } else if let detail = openWorkDetail {
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary")
                                .font(.headline)
                            Text(item.title)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                }
                .padding(20)
            }
        }
        .task(id: item.key) {
            await loadOpenWorkDetails(item: item)
        }
    }

    private func openWorkInlineError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.subheadline)
                Text("The Open Work list is unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func loadOpenWorkDetails(item: OpenWorkItem) async {
        isFetchingOpenWorkDetail = true
        openWorkDetail = nil
        openWorkDetailError = nil
        defer { isFetchingOpenWorkDetail = false }

        guard let githubService = store.githubService else {
            openWorkDetailError = "GitHub isn't connected. Add a token in Settings."
            return
        }

        do {
            openWorkDetail = try await githubService.fetchIssueDetails(
                repo: item.repository,
                number: item.number
            )
        } catch let error as GitHubError {
            switch error {
            case .unauthorized:
                openWorkDetailError = "GitHub rejected the token (HTTP 401). Update it in Settings, then refresh."
            case .forbidden:
                openWorkDetailError = "GitHub rate limit reached (HTTP 403). Try again after the limit resets."
            case .invalidResponse(let status, _) where status == 401:
                openWorkDetailError = "GitHub rejected the token (HTTP 401). Update it in Settings, then refresh."
            case .invalidResponse(let status, _) where status == 403:
                openWorkDetailError = "GitHub rate limit reached (HTTP 403). Try again after the limit resets."
            default:
                openWorkDetailError = error.localizedDescription
            }
        } catch {
            openWorkDetailError = error.localizedDescription
        }
    }

    private func dispatchOpenWorkItem(_ item: OpenWorkItem) {
        Task {
            if let detail = openWorkDetail {
                await performOpenWorkDispatch(OpenWorkDispatcher.makePayload(item: item, detail: detail))
                return
            }

            let fetchedDetail: GitHubIssueDetail?
            do {
                fetchedDetail = try await store.githubService?.fetchIssueDetails(
                    repo: item.repository,
                    number: item.number
                )
            } catch {
                openWorkDispatchFailureItem = item
                return
            }

            await performOpenWorkDispatch(OpenWorkDispatcher.makePayload(item: item, detail: fetchedDetail))
        }
    }

    private func dispatchOpenWorkTitleOnly(_ item: OpenWorkItem) {
        Task {
            await performOpenWorkDispatch(OpenWorkDispatcher.makeTitleOnlyPayload(item: item))
        }
    }

    private func performOpenWorkDispatch(_ payload: AgentDispatchPayload) async {
        do {
            try await OpenWorkDispatcher.performDispatch(
                payload: payload,
                preferences: preferencesStore
            )
            store.showToast(preferencesStore.preferredAgent == .none
                ? "Copied issue context to clipboard"
                : "Copied \(preferencesStore.preferredAgent.rawValue) command — paste in your terminal")
        } catch {
            store.showToast("Dispatch error: \(error.localizedDescription)")
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

    // MARK: - Shared Badge

    private func pillBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(color)
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
