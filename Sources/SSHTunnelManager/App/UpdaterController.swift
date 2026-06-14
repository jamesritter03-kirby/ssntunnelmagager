import Foundation
import Combine
import Sparkle

/// Thin wrapper around Sparkle's standard updater so SwiftUI can drive
/// "Check for Updates…" and reflect whether a check is currently allowed.
///
/// The feed URL and the EdDSA public key live in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`). Updates are verified against that public
/// key, so they're secure even though the app is only ad-hoc signed.
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    /// False briefly at launch / while a check is already in flight.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's automatic-check preference for the Settings toggle.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true → begins scheduled checks per the Info.plist keys.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Show Sparkle's update UI (user-initiated check).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
