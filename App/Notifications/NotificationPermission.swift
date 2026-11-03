import SwiftUI
import AppKit
import Observation
import os
import UserNotifications

private let log = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "notifications")

@MainActor
@Observable
final class NotificationPermission {
    enum State: Equatable {
        case unknown
        case notAsked
        case allowed
        case withoutBanners
        case denied
    }

    private(set) var state = State.unknown

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: state = .notAsked
        case .denied: state = .denied
        default: state = settings.alertSetting == .disabled || settings.alertStyle == .none ? .withoutBanners : .allowed
        }
    }

    func request() async {
        NSApp.activate()
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            log.info("Notification permission granted: \(granted, privacy: .public)")
        } catch {
            log.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Dowlio notifications are on"
        content.body = "You'll see a note like this when a download finishes."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) { error in
            if let error { log.error("Posting the test notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

struct NotificationPermissionRow: View {
    let permission: NotificationPermission

    var body: some View {
        HStack {
            Text(message)
                .font(DowlioDesign.TypeRole.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            switch permission.state {
            case .notAsked:
                Button("Allow Notifications") { Task { await permission.request() } }
            case .denied, .withoutBanners:
                Button("Open System Settings…") { NotificationPermission.openSystemSettings() }
            case .allowed:
                Button("Send a Test") { NotificationPermission.sendTest() }
            case .unknown:
                EmptyView()
            }
        }
        .task { await permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permission.refresh() }
        }
    }

    private var message: String {
        switch permission.state {
        case .unknown: ""
        case .notAsked: "Dowlio hasn't asked macOS to show notifications yet."
        case .allowed: "Notifications are on in macOS."
        case .withoutBanners: "macOS has Dowlio's banners turned off, so nothing appears."
        case .denied: "macOS isn't letting Dowlio show notifications."
        }
    }
}
