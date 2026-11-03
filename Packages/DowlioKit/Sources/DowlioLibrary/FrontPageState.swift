import Foundation

public enum FrontPageState: Equatable, Sendable {
    case asking(String)
    case couldntRead(CouldntRead)

    public var line: String? {
        if case .asking(let browser) = self { "Asking \(browser) for the page" } else { nil }
    }
}

public enum CouldntRead: Equatable, Sendable {
    case notABrowser(String?)
    case refused(String)
    case noPage(String)
    case noAnswer(String)

    public static let title = "Couldn't read the page"
    private static let browsers = "Send to Dowlio works in Safari, Chrome, Arc, Brave, Edge and browsers with Dowlio Connect."

    public var explanation: String {
        switch self {
        case .notABrowser(let app?): "\(app) isn't a browser. \(Self.browsers)"
        case .notABrowser(nil): "There's no browser in front. \(Self.browsers)"
        case .refused(let browser): "Dowlio isn't allowed to read \(browser)'s page. Turn on \(browser) under Dowlio in Automation settings, then send the page again."
        case .noPage(let browser): "\(browser) has no web page open in front."
        case .noAnswer(let browser): "Dowlio Connect in \(browser) didn't answer. Send the page from Dowlio Connect's button instead."
        }
    }

    public var opensAutomationSettings: Bool {
        if case .refused = self { true } else { false }
    }
}

public enum ClipboardLink {
    public static func first(in text: String?) -> URL? {
        PastedLinks.parse(text ?? "").lazy.compactMap(\.url).first
    }
}
