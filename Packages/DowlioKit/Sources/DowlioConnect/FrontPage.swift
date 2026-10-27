import DowlioLibrary
import DowlioMedia
import Foundation

public struct FrontApp: Equatable, Sendable {
    public let name: String
    public let bundleID: String?

    public init(name: String, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }
}

public enum AppleEventReply: Equatable, Sendable {
    case page(URL, title: String?)
    case refused
    case noPage
}

public enum FrontPageOutcome: Equatable, Sendable {
    case sentThroughConnect
    case read(SentPage)
    case couldntRead(CouldntRead)
}

public enum FrontPage {
    public static func read(
        _ app: FrontApp?,
        scan: @Sendable (String) async -> PageScanResult,
        appleEvents: @Sendable (FrontApp) async -> AppleEventReply?
    ) async -> FrontPageOutcome {
        guard let app else { return .couldntRead(.notABrowser(nil)) }
        switch await scan(app.name) {
        case .sent: return .sentThroughConnect
        case .noPage: return .couldntRead(.noPage(app.name))
        case .noAnswer: return .couldntRead(.noAnswer(app.name))
        case .notConnected: break
        }
        switch await appleEvents(app) {
        case nil: return .couldntRead(.notABrowser(app.name))
        case .refused: return .couldntRead(.refused(app.name))
        case .noPage: return .couldntRead(.noPage(app.name))
        case let .page(url, title):
            guard Envelope.isWebLink(url) else { return .couldntRead(.noPage(app.name)) }
            return .read(SentPage(url: url, title: title, browser: app.name))
        }
    }
}

public enum ScriptableBrowsers {
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
    ]
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    public static func script(for bundleID: String) -> String? {
        if chromium.contains(bundleID) {
            return script(bundleID, tab: "active tab", title: "title")
        }
        if safari.contains(bundleID) {
            return script(bundleID, tab: "current tab", title: "name")
        }
        return nil
    }

    private static func script(_ bundleID: String, tab: String, title: String) -> String {
        """
        with timeout of 5 seconds
            tell application id "\(bundleID)" to tell \(tab) of front window to return (URL & linefeed & \(title))
        end timeout
        """
    }

    public static func reply(_ text: String) -> AppleEventReply {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first, let url = URL(string: String(first).trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return .noPage }
        let title = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return .page(url, title: title.isEmpty ? nil : title)
    }
}
