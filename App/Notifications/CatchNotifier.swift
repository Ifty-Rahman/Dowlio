import DowlioConnect
import os
import UserNotifications

private let log = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "notifications")

@MainActor
final class CatchNotifier {
    nonisolated static let singleCategory = "caught.single"
    nonisolated static let collapsedCategory = "caught.collapsed"
    static let kept = 20

    enum Action: String, Sendable {
        case downloadInBrowser
        case show
    }

    static var categories: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(
                identifier: singleCategory,
                actions: [
                    UNNotificationAction(identifier: Action.downloadInBrowser.rawValue, title: "Download in Browser Instead"),
                    UNNotificationAction(identifier: Action.show.rawValue, title: "Show"),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: collapsedCategory,
                actions: [UNNotificationAction(identifier: Action.show.rawValue, title: "Show in Dowlio")],
                intentIdentifiers: []
            ),
        ]
    }

    nonisolated static func isCatch(_ category: String) -> Bool {
        category == singleCategory || category == collapsedCategory
    }

    private var posted: [(identifier: String, notice: CatchNotice)] = []

    func post(_ notice: CatchNotice) {
        let identifier = notice.id.uuidString
        posted.removeAll { $0.identifier == identifier }
        posted.append((identifier, notice))
        posted = posted.suffix(Self.kept)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.detail
        content.categoryIdentifier = notice.offersDownloadInBrowser ? Self.singleCategory : Self.collapsedCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { log.error("Posting a catch notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func notice(_ identifier: String) -> CatchNotice? {
        posted.last { $0.identifier == identifier }?.notice
    }
}
