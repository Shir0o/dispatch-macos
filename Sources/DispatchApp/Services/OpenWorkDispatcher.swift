import Foundation

/// One payload builder and one dispatch path for GitHub Open Work.
///
/// The list, the detail pane and the keyboard shortcut all go through these
/// functions so the prompt the user copies is identical no matter where the
/// action started.
@MainActor
public enum OpenWorkDispatcher {
    /// Builds the payload from an item and, when available, its issue detail.
    /// The title stands in for a missing body so the prompt is never empty.
    public static func makePayload(item: OpenWorkItem, detail: GitHubIssueDetail?) -> AgentDispatchPayload {
        AgentDispatchPayload(
            issueNumber: item.number,
            repository: item.repository,
            title: item.title,
            body: detail?.body ?? item.title,
            comments: detail?.comments ?? [],
            localRepoPath: nil
        )
    }

    /// Builds the payload for a detail-fetch failure: title only, no body or
    /// comments. This is what the "Send title only" alert button uses.
    public static func makeTitleOnlyPayload(item: OpenWorkItem) -> AgentDispatchPayload {
        AgentDispatchPayload(
            issueNumber: item.number,
            repository: item.repository,
            title: item.title,
            body: "",
            comments: [],
            localRepoPath: nil
        )
    }

    /// Copies the prompt and, for a real agent, opens the preferred terminal.
    /// Returns the text that was placed on the pasteboard.
    @discardableResult
    public static func performDispatch(
        payload: AgentDispatchPayload,
        preferences: PreferencesStore
    ) async throws -> String {
        // `makePayload` has no preferences, so resolve the local checkout here.
        // A caller that already supplied a path keeps it.
        let resolved: AgentDispatchPayload
        if payload.localRepoPath == nil,
           let localPath = preferences.localPath(for: payload.repository) {
            resolved = AgentDispatchPayload(
                issueNumber: payload.issueNumber,
                repository: payload.repository,
                title: payload.title,
                body: payload.body,
                comments: payload.comments,
                localRepoPath: localPath
            )
        } else {
            resolved = payload
        }

        return try await AgentDispatchService().dispatch(
            payload: resolved,
            preferredTerminal: preferences.preferredTerminal,
            agent: preferences.preferredAgent,
            agentCommand: preferences.agentCommand
        )
    }
}
