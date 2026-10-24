import AppKit
import DowlioLibrary
import UserNotifications

enum ThenAction: String, CaseIterable {
    case nothing
    case showInFinder
    case open

    var title: String {
        switch self {
        case .nothing: "Do nothing"
        case .showInFinder: "Show in Finder"
        case .open: "Open the file"
        }
    }
}

/// Tells the user when downloads finish. Finishes within five seconds of each other share one
/// notification, and only a single finish runs the "Then" action.
@MainActor
final class FinishNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "finished"
    private static let showInFinderAction = "showInFinder"
    private static let openAction = "open"

    private var watcher = FinishWatcher()
    private var grouper = FinishGrouper()
    private var waiting: Task<Void, Never>?
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(identifier: Self.showInFinderAction, title: "Show in Finder"),
                UNNotificationAction(identifier: Self.openAction, title: "Open"),
            ],
            intentIdentifiers: []
        )])
    }

    /// Asks once, when the first download is added, so the question comes with a reason.
    func askPermissionIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func update(_ rows: [DownloadRow]) {
        let now = Date()
        for row in watcher.newlyFinished(in: rows) { grouper.add(row, at: now) }
        guard let due = grouper.dueDate else { return }
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self, let notice = grouper.takeDue(at: Date()) else { return }
            deliver(notice)
        }
    }

    private func deliver(_ notice: FinishNotice) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKey.notifiesWhenFinished) == nil || defaults.bool(forKey: SettingsKey.notifiesWhenFinished) {
            post(notice)
        }
        guard notice.runsThenAction, let file = notice.rows.first?.finishedFile else { return }
        switch ThenAction(rawValue: defaults.string(forKey: SettingsKey.thenAction) ?? "") ?? .nothing {
        case .nothing: break
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([file])
        case .open: NSWorkspace.shared.open(file)
        }
    }

    private func post(_ notice: FinishNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if notice.rows.count == 1, let file = notice.rows.first?.finishedFile {
            content.categoryIdentifier = Self.category
            content.userInfo = ["file": file.path]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let path = response.notification.request.content.userInfo["file"] as? String
        await MainActor.run {
            guard let path else {
                AppDelegate.model?.showLibraryWindow()
                return
            }
            let file = URL(filePath: path)
            switch action {
            case Self.openAction: NSWorkspace.shared.open(file)
            case Self.showInFinderAction: NSWorkspace.shared.activateFileViewerSelecting([file])
            default: AppDelegate.model?.showLibraryWindow()
            }
        }
    }
}
