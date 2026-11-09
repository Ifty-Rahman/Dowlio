import AppKit
import DowlioLibrary
import Foundation
import Observation
import Sparkle
import UserNotifications

@MainActor
@Observable
final class AppUpdater {
    nonisolated static let noticeCategory = "update"
    private static let noticeIdentifier = "update-available"

    private(set) var canCheck = false
    private(set) var waitingVersion: String?
    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var started = false
    @ObservationIgnored private var watching: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate
        )
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        canCheck = controller.updater.canCheckForUpdates
        watching = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheck = canCheck }
        }
        delegate.found = { [weak self] version, remindsUser in self?.found(version, remindsUser: remindsUser) }
        delegate.seen = { [weak self] in self?.seen() }
        startIfWelcomed()
        if !started, DebugLaunch.checksForUpdates { canCheck = true }
        if let version = DebugLaunch.updateReminder {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.found(version, remindsUser: true)
            }
        }
    }

    func startIfWelcomed() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.hasSeenWelcome) else { return }
        start()
    }

    func checkNow() {
        start()
        controller.checkForUpdates(nil)
    }

    private func start() {
        guard !started, DebugLaunch.checksForUpdates else { return }
        started = true
        controller.startUpdater()
    }

    func showUpdate() {
        NSApp.activate()
        checkNow()
    }

    private func found(_ version: String, remindsUser: Bool) {
        waitingVersion = version
        NSApp.dockTile.badgeLabel = UpdateNotice(version: version).dockBadge
        guard remindsUser else { return }
        let notice = UpdateNotice(version: version)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = Self.noticeCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.noticeIdentifier, content: content, trigger: nil))
    }

    private func seen() {
        waitingVersion = nil
        NSApp.dockTile.badgeLabel = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.noticeIdentifier])
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    nonisolated(unsafe) var found: (@MainActor (String, Bool) -> Void)?
    nonisolated(unsafe) var seen: (@MainActor () -> Void)?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        DebugLaunch.updateFeed
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { found?(version, !handleShowingUpdate) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { seen?() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { seen?() }
    }
}
