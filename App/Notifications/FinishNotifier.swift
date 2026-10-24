import AppKit
import DowlioLibrary
import os
import UserNotifications

private let log = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "notifications")

@MainActor
final class FinishNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "finished"

    private var watcher = FinishWatcher()
    private var grouper = FinishGrouper()
    private var armedFor: Date?
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [SettingsKey.notifiesWhenFinished: true])
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(identifier: ThenAction.showInFinder.rawValue, title: "Show in Finder"),
                UNNotificationAction(identifier: ThenAction.open.rawValue, title: "Open"),
            ],
            intentIdentifiers: []
        )])
    }

    /// The question comes when the first download is added, so it has a reason.
    func askPermissionIfNeeded() {
        Task {
            let status = await center.notificationSettings().authorizationStatus
            log.info("Notification permission is \(status.rawValue, privacy: .public)")
            guard status == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.info("Notification permission granted: \(granted, privacy: .public)")
            } catch {
                log.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func update(_ rows: [DownloadRow]) {
        for row in watcher.newlyFinished(in: rows) { grouper.add(row, at: Date()) }
        guard let due = grouper.dueDate, armedFor != due else { return }
        armedFor = due
        Task { [weak self] in
            // A little past the due time, so the timer never wakes to find nothing due.
            try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0) + 0.05))
            guard let self else { return }
            armedFor = nil
            if let notice = grouper.takeDue(at: Date()) {
                log.info("Delivering a notice for \(notice.rows.count, privacy: .public) finished downloads")
                deliver(notice)
            }
        }
    }

    private func deliver(_ notice: FinishNotice) {
        if UserDefaults.standard.bool(forKey: SettingsKey.notifiesWhenFinished) { post(notice) }
        guard notice.runsThenAction, let file = notice.singleFile else { return }
        Self.perform(ThenAction(saved: UserDefaults.standard.string(forKey: SettingsKey.thenAction) ?? ""), on: file)
    }

    private func post(_ notice: FinishNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if let file = notice.singleFile {
            content.categoryIdentifier = Self.category
            content.userInfo = ["file": file.path]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error {
                log.error("Posting a notification failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("Posted a notification")
            }
        }
    }

    private static func perform(_ action: ThenAction, on file: URL) {
        switch action {
        case .nothing: break
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([file])
        case .open: NSWorkspace.shared.open(file)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = ThenAction(rawValue: response.actionIdentifier)
        let path = response.notification.request.content.userInfo["file"] as? String
        await MainActor.run {
            if let path, let action {
                Self.perform(action, on: URL(filePath: path))
            } else {
                AppDelegate.model?.showLibraryWindow()
            }
        }
    }
}
