import AppKit
import DowlioCore
import DowlioLibrary
import os
import UserNotifications

private let log = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "notifications")

@MainActor
final class FinishNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "finished"
    nonisolated private static let problemCategory = "problem"
    nonisolated private static let retryAction = "retry"
    nonisolated private static let showAction = "show"

    private var watcher = FinishWatcher()
    private var grouper = NoticeGrouper()
    private var problemWatcher = ProblemWatcher()
    private var problemGrouper = NoticeGrouper()
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [SettingsKey.notifiesWhenFinished: true, SettingsKey.notifiesOnProblems: true])
        center.delegate = self
        center.setNotificationCategories(CatchNotifier.categories.union([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(identifier: ThenAction.showInFinder.rawValue, title: "Show in Finder"),
                UNNotificationAction(identifier: ThenAction.open.rawValue, title: "Open"),
            ],
            intentIdentifiers: []
        ), UNNotificationCategory(
            identifier: Self.problemCategory,
            actions: [
                UNNotificationAction(identifier: Self.retryAction, title: "Retry"),
                UNNotificationAction(identifier: Self.showAction, title: "Show in Dowlio"),
            ],
            intentIdentifiers: []
        )]))
    }

    func askPermissionIfNeeded() {
        Task {
            let permission = NotificationPermission()
            await permission.refresh()
            log.info("Notification permission state: \(String(describing: permission.state), privacy: .public)")
            guard permission.state == .notAsked else { return }
            await permission.request()
        }
    }

    func update(_ rows: [DownloadRow]) {
        let now = Date()
        for row in watcher.newlyFinished(in: rows) {
            let shown = grouper.add(row, at: now)
            deliver(FinishNotice(rows: shown.rows, group: shown.group))
        }
        for row in problemWatcher.newProblems(in: rows) {
            let shown = problemGrouper.add(row, at: now)
            deliver(ProblemNotice(rows: shown.rows, group: shown.group))
        }
    }

    private func deliver(_ notice: FinishNotice) {
        if UserDefaults.standard.bool(forKey: SettingsKey.notifiesWhenFinished) {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            if let file = notice.singleFile {
                content.categoryIdentifier = Self.category
                content.userInfo = ["file": file.path]
            }
            post(content, as: notice.group)
        }
        guard notice.runsThenAction, let file = notice.singleFile else { return }
        Self.perform(ThenAction(saved: UserDefaults.standard.string(forKey: SettingsKey.thenAction) ?? ""), on: file)
    }

    private func deliver(_ notice: ProblemNotice) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.notifiesOnProblems) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = Self.problemCategory
        if let id = notice.retryable { content.userInfo = ["retry": id.rawValue.uuidString] }
        post(content, as: notice.group)
    }

    private func post(_ content: UNMutableNotificationContent, as group: UUID) {
        log.info("Posting \(content.title, privacy: .public)")
        center.add(UNNotificationRequest(identifier: group.uuidString, content: content, trigger: nil)) { error in
            if let error { log.error("Posting a notification failed: \(error.localizedDescription, privacy: .public)") }
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
        if CatchNotifier.isCatch(response.notification.request.content.categoryIdentifier) {
            let identifier = response.notification.request.identifier
            let action = CatchNotifier.Action(rawValue: response.actionIdentifier) ?? .show
            await MainActor.run {
                AppDelegate.model?.answerCatchNotification(identifier, action: action)
            }
            return
        }
        if response.notification.request.content.categoryIdentifier == Self.problemCategory {
            let retry = (response.notification.request.content.userInfo["retry"] as? String).flatMap(UUID.init(uuidString:))
            let retries = response.actionIdentifier == Self.retryAction
            await MainActor.run {
                if retries, let retry, let row = AppDelegate.model?.row(DownloadID(rawValue: retry)) {
                    AppDelegate.model?.retry(row)
                } else {
                    AppDelegate.model?.showLibraryWindow()
                }
            }
            return
        }
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
