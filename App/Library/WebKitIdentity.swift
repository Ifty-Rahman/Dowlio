import DowlioCore
import Foundation
import WebKit

final class WebKitIdentity: @unchecked Sendable {
    static let shared = WebKitIdentity()
    private static let savedKey = "webKitUserAgent"

    private let lock = NSLock()
    private var identity = BrowserIdentity(userAgent: UserDefaults.standard.string(forKey: savedKey))

    var current: BrowserIdentity { lock.withLock { identity } }

    @MainActor
    func read() async {
        let webView = WKWebView(frame: .zero)
        guard let agent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String, !agent.isEmpty else { return }
        UserDefaults.standard.set(agent, forKey: Self.savedKey)
        lock.withLock { identity = BrowserIdentity(userAgent: agent) }
    }
}
