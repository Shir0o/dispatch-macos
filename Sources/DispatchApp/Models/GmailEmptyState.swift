import Foundation

// MARK: - GmailSyncState

/// The outcome of the most recent Gmail sync attempt.
public enum GmailSyncState: Equatable, Sendable {
    case unknown
    case connected
    case failed(String)

    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

// MARK: - GmailEmptyState

/// Copy and affordance for the Gmail stream when there are no items.
///
/// An empty inbox and a broken connection used to render the same "Inbox Zero"
/// card, so a failed sign-in looked identical to having no mail. The state is
/// derived here, away from SwiftUI, so the distinction is testable.
public struct GmailEmptyState: Sendable, Equatable {
    public let title: String
    public let message: String
    public let symbol: String
    /// True when the card should offer a route to Settings to fix credentials.
    public let offersSettings: Bool

    public init(title: String, message: String, symbol: String, offersSettings: Bool) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.offersSettings = offersSettings
    }

    public static func make(isConnected: Bool, syncState: GmailSyncState) -> GmailEmptyState {
        guard isConnected else {
            return GmailEmptyState(
                title: "Gmail isn't connected",
                message: "Add your Google Client ID and sign in from Settings to load your inbox.",
                symbol: "envelope.badge",
                offersSettings: true
            )
        }

        if let failure = syncState.failureMessage {
            return GmailEmptyState(
                title: "Couldn't load Gmail",
                message: failure,
                symbol: "exclamationmark.triangle",
                offersSettings: true
            )
        }

        if syncState == .unknown {
            return GmailEmptyState(
                title: "Loading Gmail…",
                message: "Fetching your inbox.",
                symbol: "envelope.open",
                offersSettings: false
            )
        }

        return GmailEmptyState(
            title: "Inbox Zero",
            message: "No unread messages in your Gmail inbox.",
            symbol: "envelope.open",
            offersSettings: false
        )
    }
}
