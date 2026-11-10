import SwiftUI
import Sparkle

/// Observable wrapper around Sparkle's SPUStandardUpdaterController.
@MainActor
public final class UpdateController: ObservableObject {
    public static let shared = UpdateController()

    private var updaterController: SPUStandardUpdaterController?

    @Published public private(set) var canCheckForUpdates: Bool = false

    public init() {
        // Start updater controller only when running as an app bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            self.updaterController = controller
            self.canCheckForUpdates = controller.updater.canCheckForUpdates
        }
    }

    public func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    public var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? true }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }
}
