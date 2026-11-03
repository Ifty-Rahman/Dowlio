import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater {
    private(set) var canCheck = false
    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var watching: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: DebugLaunch.checksForUpdates, updaterDelegate: delegate, userDriverDelegate: delegate
        )
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        canCheck = controller.updater.canCheckForUpdates
        watching = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheck = canCheck }
        }
    }

    func checkNow() {
        controller.checkForUpdates(nil)
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        DebugLaunch.updateFeed
    }
}
