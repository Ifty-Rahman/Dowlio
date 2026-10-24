import AppKit
import DowlioLibrary
import UserNotifications

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
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
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
            if let notice = grouper.takeDue(at: Date()) { deliver(notice) }
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
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
