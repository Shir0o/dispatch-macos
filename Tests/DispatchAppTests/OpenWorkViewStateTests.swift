import Foundation
import Testing
@testable import DispatchApp

/// Every row of the design's view-state table, plus truncation, error actions
/// and the sidebar capsule. Fixed dates keep the relative copy deterministic.
@Suite("OpenWorkViewState Tests")
struct OpenWorkViewStateTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func make(
        _ status: OpenWorkStatus,
        visible: Int,
        hidden: Int,
        hasSummary: Bool = false
    ) -> OpenWorkPresentation {
        OpenWorkPresentation(
            status: status,
            visibleCount: visible,
            hiddenCount: hidden,
            hasSummary: hasSummary,
            now: now
        )
    }

    // MARK: - State Table

    @Test("Disconnected overrides every other row")
    func disconnected() {
        let presentation = make(
            OpenWorkStatus(phase: .idle, error: .notConfigured),
            visible: 0,
            hidden: 0
        )

        #expect(presentation.headerText == "GitHub isn't connected")
        #expect(presentation.secondaryText == "")
        #expect(presentation.emptyText == "Connect a GitHub token in Settings.")
        #expect(presentation.bannerText == nil)
        #expect(presentation.truncationText == nil)
        #expect(presentation.action == PresentationAction(
            label: "Open Settings",
            kind: .openSettings,
            isEnabled: true
        ))
        #expect(presentation.sidebarText == "—")
    }

    @Test("Running with no items shows the loading header")
    func runningNoItems() {
        let presentation = make(OpenWorkStatus(phase: .running), visible: 0, hidden: 0)

        #expect(presentation.headerText == "Loading Open Work…")
        #expect(presentation.secondaryText == "")
        #expect(presentation.emptyText == nil)
        #expect(presentation.bannerText == nil)
        #expect(presentation.action == PresentationAction(
            label: "Refreshing…",
            kind: .refresh,
            isEnabled: false
        ))
        #expect(presentation.sidebarText == "—")
    }

    @Test("Running with items keeps the previous counts and disables refresh")
    func runningWithItems() {
        let status = OpenWorkStatus(
            phase: .running,
            lastSuccess: now.addingTimeInterval(-300),
            matchedCount: 42,
            fetchedCount: 42,
            updatedCount: 3
        )

        let presentation = make(status, visible: 5, hidden: 1)

        #expect(presentation.headerText == "5 visible · 1 hidden · 42 matched")
        #expect(presentation.secondaryText == "3 updated · last successful refresh 5m ago")
        #expect(presentation.emptyText == nil)
        #expect(presentation.bannerText == nil)
        #expect(presentation.action == PresentationAction(
            label: "Refreshing…",
            kind: .refresh,
            isEnabled: false
        ))
        #expect(presentation.sidebarText == "5 open items")
    }

    @Test("Idle with no items, no summary and no error")
    func idleEmptyClean() {
        let presentation = make(OpenWorkStatus(phase: .idle), visible: 0, hidden: 0)

        #expect(presentation.headerText == "Not loaded this session")
        #expect(presentation.secondaryText == "")
        #expect(presentation.emptyText == "Open Work has not loaded this session.")
        #expect(presentation.bannerText == nil)
        #expect(presentation.action == PresentationAction(
            label: "Refresh",
            kind: .refresh,
            isEnabled: true
        ))
        #expect(presentation.sidebarText == "—")
    }

    @Test("Idle with no items and an error offers the error action")
    func idleEmptyError() {
        let presentation = make(
            OpenWorkStatus(phase: .idle, error: .server(status: 502)),
            visible: 0,
            hidden: 0
        )

        #expect(presentation.headerText == "Not loaded this session")
        #expect(presentation.emptyText == "Could not load Open Work: GitHub server error.")
        #expect(presentation.action == PresentationAction(
            label: "Retry",
            kind: .retry(until: nil),
            isEnabled: true
        ))
        #expect(presentation.sidebarText == "—")
    }

    @Test("Idle with a summary shows the last run in the header")
    func idleWithSummary() {
        let status = OpenWorkStatus(
            phase: .idle,
            lastSuccess: now.addingTimeInterval(-7200),
            matchedCount: 89,
            fetchedCount: 89
        )

        let presentation = make(status, visible: 0, hidden: 0, hasSummary: true)

        #expect(presentation.headerText == "Not loaded this session · last successful refresh 2h ago · 89 matched")
        #expect(presentation.secondaryText == "")
        #expect(presentation.emptyText == "Open Work has not loaded this session.")
        #expect(presentation.action.kind == .refresh)
        #expect(presentation.sidebarText == "—")
    }

    @Test("Idle with a summary and an error keeps the summary and offers the error action")
    func idleWithSummaryError() {
        let status = OpenWorkStatus(
            phase: .idle,
            lastSuccess: now.addingTimeInterval(-7200),
            matchedCount: 89,
            fetchedCount: 89,
            error: .unauthorized
        )

        let presentation = make(status, visible: 0, hidden: 0, hasSummary: true)

        #expect(presentation.headerText == "Not loaded this session · last successful refresh 2h ago · 89 matched")
        #expect(presentation.emptyText == "Could not load Open Work: GitHub rejected the token.")
        #expect(presentation.action == PresentationAction(
            label: "Update token",
            kind: .updateToken,
            isEnabled: true
        ))
    }

    @Test("Ready with no items is empty, not an error")
    func readyEmpty() {
        let status = OpenWorkStatus(
            phase: .ready,
            lastSuccess: now.addingTimeInterval(-30),
            matchedCount: 0,
            fetchedCount: 0
        )

        let presentation = make(status, visible: 0, hidden: 0)

        #expect(presentation.headerText == "0 visible · 0 hidden · 0 matched")
        #expect(presentation.emptyText == "No open issues or pull requests involve you.")
        #expect(presentation.bannerText == nil)
        #expect(presentation.action == PresentationAction(
            label: "Refresh",
            kind: .refresh,
            isEnabled: true
        ))
        #expect(presentation.sidebarText == "—")
    }

    @Test("Ready with every item hidden offers clear-all")
    func allHidden() {
        let status = OpenWorkStatus(
            phase: .ready,
            lastSuccess: now.addingTimeInterval(-30),
            matchedCount: 12,
            fetchedCount: 12
        )

        let presentation = make(status, visible: 0, hidden: 12)

        #expect(presentation.headerText == "0 visible · 12 hidden · 12 matched")
        #expect(presentation.emptyText == "All 12 items are hidden.")
        #expect(presentation.bannerText == nil)
        #expect(presentation.action == PresentationAction(
            label: "Clear all hidden keys",
            kind: .clearHidden,
            isEnabled: true
        ))
        #expect(presentation.sidebarText == "—")
    }

    @Test("All hidden uses the singular for one item")
    func allHiddenSingular() {
        let status = OpenWorkStatus(
            phase: .ready,
            lastSuccess: now,
            matchedCount: 1,
            fetchedCount: 1
        )

        let presentation = make(status, visible: 0, hidden: 1)
        #expect(presentation.emptyText == "All 1 item is hidden.")
    }

    @Test("Ready with rows and a stale error keeps the rows and shows the banner")
    func readyStale() {
        let reset = now.addingTimeInterval(600)
        let status = OpenWorkStatus(
            phase: .ready,
            lastSuccess: now.addingTimeInterval(-900),
            matchedCount: 7,
            fetchedCount: 7,
            updatedCount: 4,
            error: .forbidden(resetAt: reset)
        )

        let presentation = make(status, visible: 5, hidden: 2)

        #expect(presentation.headerText == "5 visible · 2 hidden · 7 matched")
        #expect(presentation.secondaryText == "4 updated · last successful refresh 15m ago")
        #expect(presentation.emptyText == nil)
        #expect(presentation.bannerText == "Could not refresh Open Work: GitHub rate limit reached.")
        #expect(presentation.action.kind == .retry(until: reset))
        #expect(presentation.action.isEnabled == false)
        #expect(presentation.action.label.hasPrefix("Retry at "))
        #expect(presentation.sidebarText == "5 open items")
    }

    @Test("Ready with rows and no error is the normal state")
    func readyNormal() {
        let status = OpenWorkStatus(
            phase: .ready,
            lastSuccess: now.addingTimeInterval(-60),
            matchedCount: 4,
            fetchedCount: 4,
            updatedCount: 2
        )

        let presentation = make(status, visible: 3, hidden: 1)

        #expect(presentation.headerText == "3 visible · 1 hidden · 4 matched")
        #expect(presentation.secondaryText == "2 updated · last successful refresh 1m ago")
        #expect(presentation.emptyText == nil)
        #expect(presentation.bannerText == nil)
        #expect(presentation.truncationText == nil)
        #expect(presentation.action == PresentationAction(
            label: "Refresh",
            kind: .refresh,
            isEnabled: true
        ))
        #expect(presentation.sidebarText == "3 open items")
    }

    // MARK: - Truncation

    @Test("Truncation discloses fetched and matched counts")
    func truncationText() {
        let status = OpenWorkStatus(
            phase: .ready,
            lastSuccess: now,
            matchedCount: 1200,
            fetchedCount: 400,
            truncated: true
        )

        let presentation = make(status, visible: 400, hidden: 3)

        #expect(presentation.truncationText == "400 fetched of 1200 matched (400-item cap; GitHub reports at most 1,000)")
    }

    @Test("Truncation is suppressed for the disconnected row")
    func truncationSuppressedWhenDisconnected() {
        let status = OpenWorkStatus(
            phase: .idle,
            matchedCount: 1200,
            fetchedCount: 400,
            truncated: true,
            error: .notConfigured
        )

        let presentation = make(status, visible: 0, hidden: 0)
        #expect(presentation.truncationText == nil)
    }

    // MARK: - Error Actions

    @Test("401 offers Update token")
    func unauthorizedAction() {
        let action = make(
            OpenWorkStatus(phase: .idle, error: .unauthorized),
            visible: 0,
            hidden: 0
        ).action

        #expect(action == PresentationAction(label: "Update token", kind: .updateToken, isEnabled: true))
    }

    @Test("403 with a future reset disables retry until then")
    func forbiddenFuture() {
        let reset = now.addingTimeInterval(300)
        let action = make(
            OpenWorkStatus(phase: .idle, error: .forbidden(resetAt: reset)),
            visible: 0,
            hidden: 0
        ).action

        #expect(action.kind == .retry(until: reset))
        #expect(action.isEnabled == false)
        #expect(action.label.hasPrefix("Retry at "))
    }

    @Test("403 with a past reset enables retry")
    func forbiddenPast() {
        let reset = now.addingTimeInterval(-300)
        let action = make(
            OpenWorkStatus(phase: .idle, error: .forbidden(resetAt: reset)),
            visible: 0,
            hidden: 0
        ).action

        #expect(action.kind == .retry(until: reset))
        #expect(action.isEnabled == true)
    }

    @Test("403 without a reset offers Update token")
    func forbiddenNoReset() {
        let action = make(
            OpenWorkStatus(phase: .idle, error: .forbidden(resetAt: nil)),
            visible: 0,
            hidden: 0
        ).action

        #expect(action == PresentationAction(label: "Update token", kind: .updateToken, isEnabled: true))
    }

    @Test("Retryable errors offer Retry")
    func retryableActions() {
        let errors: [OpenWorkFetchError] = [
            .notFound,
            .server(status: 500),
            .decoding,
            .transport
        ]

        for error in errors {
            let action = make(
                OpenWorkStatus(phase: .idle, error: error),
                visible: 0,
                hidden: 0
            ).action

            #expect(action == PresentationAction(label: "Retry", kind: .retry(until: nil), isEnabled: true))
        }
    }

    @Test("notConfigured offers Open Settings")
    func notConfiguredAction() {
        let action = make(
            OpenWorkStatus(phase: .idle, error: .notConfigured),
            visible: 0,
            hidden: 0
        ).action

        #expect(action == PresentationAction(label: "Open Settings", kind: .openSettings, isEnabled: true))
    }

    // MARK: - Sidebar

    @Test("Sidebar shows a neutral count only when items are visible")
    func sidebarText() {
        let ready = OpenWorkStatus(
            phase: .ready,
            lastSuccess: now.addingTimeInterval(-30),
            matchedCount: 8,
            fetchedCount: 8
        )

        #expect(make(ready, visible: 1, hidden: 0).sidebarText == "1 open item")
        #expect(make(ready, visible: 8, hidden: 0).sidebarText == "8 open items")
        #expect(make(ready, visible: 0, hidden: 8).sidebarText == "—")
        #expect(make(OpenWorkStatus(phase: .idle), visible: 0, hidden: 0).sidebarText == "—")
    }

    @Test("Sidebar keeps the count while a refresh runs with items")
    func sidebarDuringRefresh() {
        let running = OpenWorkStatus(
            phase: .running,
            lastSuccess: now.addingTimeInterval(-30),
            matchedCount: 2,
            fetchedCount: 2
        )

        #expect(make(running, visible: 2, hidden: 0).sidebarText == "2 open items")
    }
}
