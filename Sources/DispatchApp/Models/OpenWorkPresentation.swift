import Foundation

// MARK: - OpenWorkAction

/// The action the Open Work header or empty state offers for the current state.
public enum OpenWorkAction: Equatable, Sendable {
    case openSettings
    case updateToken
    /// Retry is disabled until `until`, when a rate-limit reset time is known.
    case retry(until: Date?)
    case refresh
    case clearHidden
}

// MARK: - PresentationAction

/// One labelled, enablement-aware action derived from `OpenWorkStatus`.
public struct PresentationAction: Equatable, Sendable {
    public let label: String
    public let kind: OpenWorkAction
    public let isEnabled: Bool

    public init(label: String, kind: OpenWorkAction, isEnabled: Bool) {
        self.label = label
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

// MARK: - OpenWorkPresentation

/// Pure derivation of every piece of Open Work copy from the store's status.
///
/// The view owns layout and interaction only. Each row of the design's view-state
/// table maps to exactly one `OpenWorkPresentation`, so the copy and error
/// actions can be tested without a running app or a SwiftUI host.
///
/// `status.error == .notConfigured` is the disconnected row. The view injects
/// that error when the store is not connected, because a cleared store resets
/// its status to a fresh `.idle` without an error.
public struct OpenWorkPresentation: Sendable, Equatable {
    /// Header line one: the condition, or the visible/hidden/matched counts.
    public let headerText: String
    /// Header line two: updated count and last successful refresh, when known.
    public let secondaryText: String
    /// The 400-item cap notice, when the last result was truncated.
    public let truncationText: String?
    /// Body copy when there are no visible rows.
    public let emptyText: String?
    /// Stale-data banner when rows are visible and the last refresh failed.
    public let bannerText: String?
    /// The neutral GitHub sidebar capsule, or `"—"`.
    public let sidebarText: String
    /// The state's primary action. The view renders Refresh separately.
    public let action: PresentationAction

    public init(
        status: OpenWorkStatus,
        visibleCount: Int,
        hiddenCount: Int,
        hasSummary: Bool,
        now: Date
    ) {
        let counts = "\(visibleCount) visible · \(hiddenCount) hidden · \(status.matchedCount) matched"
        let lastRefresh = status.lastSuccess.map {
            "last successful refresh \(Self.relativeTime(from: $0, to: now))"
        }
        let updatedLine = "\(status.updatedCount) updated"

        // The sidebar capsule: a neutral count only once work is loaded and at
        // least one item is visible. Otherwise it is an em dash, never zero.
        self.sidebarText = visibleCount > 0
            ? "\(visibleCount) open item\(visibleCount == 1 ? "" : "s")"
            : "—"

        // Truncation is disclosed whenever the last successful run hit the cap.
        self.truncationText = status.truncated && !Self.isDisconnected(status)
            ? "\(status.fetchedCount) fetched of \(status.matchedCount) matched "
                + "(400-item cap; GitHub reports at most 1,000)"
            : nil

        if Self.isDisconnected(status) {
            // Disconnected overrides every other row.
            self.headerText = "GitHub isn't connected"
            self.secondaryText = ""
            self.emptyText = "Connect a GitHub token in Settings."
            self.bannerText = nil
            self.action = PresentationAction(
                label: "Open Settings",
                kind: .openSettings,
                isEnabled: true
            )
            return
        }

        self.action = Self.action(for: status, visibleCount: visibleCount, hiddenCount: hiddenCount, now: now)

        switch status.phase {
        case .running:
            let hasItems = visibleCount > 0 || hiddenCount > 0
            self.headerText = hasItems ? counts : "Loading Open Work…"
            self.secondaryText = lastRefresh.map { "\(updatedLine) · \($0)" } ?? ""
            // Rows stay while refreshing; with none there is nothing to state
            // except the loading header itself.
            self.emptyText = nil
            self.bannerText = nil

        case .idle:
            if hasSummary, let lastRefresh {
                self.headerText = "Not loaded this session · \(lastRefresh) · \(status.matchedCount) matched"
            } else {
                self.headerText = "Not loaded this session"
            }
            self.secondaryText = ""

            if let error = status.error {
                self.emptyText = "Could not load Open Work: \(Self.reason(for: error))."
            } else {
                self.emptyText = "Open Work has not loaded this session."
            }
            self.bannerText = nil

        case .ready:
            self.headerText = counts
            self.secondaryText = lastRefresh.map { "\(updatedLine) · \($0)" } ?? updatedLine

            if visibleCount == 0, hiddenCount == 0 {
                self.emptyText = "No open issues or pull requests involve you."
            } else if visibleCount == 0 {
                let noun = hiddenCount == 1 ? "item is" : "items are"
                self.emptyText = "All \(hiddenCount) \(noun) hidden."
            } else {
                self.emptyText = nil
            }

            if let error = status.error, visibleCount > 0 {
                self.bannerText = "Could not refresh Open Work: \(Self.reason(for: error))."
            } else {
                self.bannerText = nil
            }
        }
    }

    // MARK: - Row Predicates

    private static func isDisconnected(_ status: OpenWorkStatus) -> Bool {
        if case .notConfigured = status.error { return true }
        return false
    }

    // MARK: - Actions

    private static func action(
        for status: OpenWorkStatus,
        visibleCount: Int,
        hiddenCount: Int,
        now: Date
    ) -> PresentationAction {
        if status.phase == .running {
            return PresentationAction(label: "Refreshing…", kind: .refresh, isEnabled: false)
        }

        if let error = status.error {
            return errorAction(for: error, now: now)
        }

        // All hidden: the only useful inverse in v1 is a bulk clear.
        if status.phase == .ready, visibleCount == 0, hiddenCount > 0 {
            return PresentationAction(label: "Clear all hidden keys", kind: .clearHidden, isEnabled: true)
        }

        return PresentationAction(label: "Refresh", kind: .refresh, isEnabled: true)
    }

    private static func errorAction(for error: OpenWorkFetchError, now: Date) -> PresentationAction {
        switch error {
        case .notConfigured:
            return PresentationAction(label: "Open Settings", kind: .openSettings, isEnabled: true)
        case .unauthorized:
            return PresentationAction(label: "Update token", kind: .updateToken, isEnabled: true)
        case .forbidden(let resetAt):
            guard let resetAt else {
                // No reset time: the token cannot satisfy the request either way.
                return PresentationAction(label: "Update token", kind: .updateToken, isEnabled: true)
            }
            return PresentationAction(
                label: "Retry at \(timeText(resetAt))",
                kind: .retry(until: resetAt),
                isEnabled: now >= resetAt
            )
        case .notFound, .server, .decoding, .transport:
            return PresentationAction(label: "Retry", kind: .retry(until: nil), isEnabled: true)
        }
    }

    // MARK: - Copy

    /// The user-facing reason inside "Could not load Open Work: …".
    private static func reason(for error: OpenWorkFetchError) -> String {
        switch error {
        case .notConfigured:
            return "GitHub isn't connected"
        case .unauthorized:
            return "GitHub rejected the token"
        case .forbidden:
            return "GitHub rate limit reached"
        case .notFound:
            return "Open Work endpoint not found"
        case .server:
            return "GitHub server error"
        case .decoding:
            return "GitHub returned an unexpected response"
        case .transport:
            return "Network unavailable"
        }
    }

    /// A fixed `HH:mm` clock for a rate-limit reset, independent of locale.
    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Compact relative text ("just now", "7m ago", "2h ago") that does not
    /// depend on the system locale, so the header stays testable.
    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }

        return "\(days / 7)w ago"
    }
}
