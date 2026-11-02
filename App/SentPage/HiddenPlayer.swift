import AppKit
import DowlioCore
import DowlioMedia
import WebKit

@MainActor
final class HiddenPlayer: NSObject {
    static let longestPlay: Duration = .seconds(15)
    static let quietAfterMedia: Duration = .seconds(3)
    static let longestRead: Duration = .seconds(3)

    static func play(_ page: SentPage) async -> PlayedPage {
        let player = HiddenPlayer(page: page)
        return await withTaskCancellationHandler {
            await player.run()
        } onCancel: {
            Task { @MainActor in player.finish(reading: false) }
        }
    }

    private let page: SentPage
    private var found: [WatchedRequest] = []
    private var frames: [WKFrameInfo] = []
    private var agent: String?
    private var webView: WKWebView?
    private var window: NSWindow?
    private var waiting: CheckedContinuation<PlayedPage, Never>?
    private var deadline: Task<Void, Never>?
    private var readLimit: Task<Void, Never>?
    private var quiet: Task<Void, Never>?
    private var hasLoaded = false
    private var isFinished = false

    private init(page: SentPage) {
        self.page = page
    }

    private func run() async -> PlayedPage {
        await withCheckedContinuation { continuation in
            waiting = continuation
            if isFinished { return finish(reading: false) }
            Task { await start() }
        }
    }

    private func start() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        for script in PageWatcher.userScripts() { configuration.userContentController.addUserScript(script) }
        configuration.userContentController.add(MessageRelay(self), name: PageWatcher.handlerName)
        for cookie in cookies { await configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
        guard !isFinished else { return }

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = page.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.contentView = webView
        window.orderBack(nil)
        self.webView = webView
        self.window = window

        var request = URLRequest(url: page.url)
        if let referrer = page.watched.first?.referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
        webView.load(request)
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.longestPlay)
            self?.finish()
        }
    }

    private var cookies: [HTTPCookie] {
        let site = PageAnalyzer.site(of: page.url)
        let domain = "." + (site.split(separator: ":").first.map(String.init) ?? site)
        let secure = page.url.scheme?.lowercased() == "https" ? "TRUE" : "FALSE"
        return page.cookies.compactMap { cookie in
            HTTPCookie(properties: [.name: cookie.name, .value: cookie.value, .domain: domain, .path: "/", .secure: secure])
        }
    }

    fileprivate func receive(_ body: Any, from frame: WKFrameInfo) {
        guard !isFinished, let message = body as? [String: Any] else { return }
        if message["scanReady"] != nil {
            if frames.count < PageWatcher.framesRead { frames.append(frame) }
            return
        }
        if agent == nil { agent = PageWatcher.agent(in: message) }
        guard let request = PageWatcher.request(from: message, on: page.url), !found.contains(where: { $0.url == request.url }) else { return }
        found.append(request)
        guard request.kind == .manifest || isSameSite(request.referrer) else { return }
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: Self.quietAfterMedia)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    fileprivate func finish(reading: Bool = true) {
        guard !isFinished || !reading else { return }
        isFinished = true
        deadline?.cancel()
        quiet?.cancel()
        guard reading, webView != nil else { return close() }
        Task {
            await readRenderedPage()
            close()
        }
        readLimit = Task {
            try? await Task.sleep(for: Self.longestRead)
            close()
        }
    }

    private struct RenderedPage {
        var scan = PageScan([:])
        var html: String?
    }

    private var rendered = RenderedPage()

    private func readRenderedPage() async {
        guard let webView else { return }
        let read = await PageWatcher.render(webView, frames: frames)
        guard waiting != nil else { return }
        rendered.html = read.html
        rendered.scan = read.scan
    }

    private func close() {
        guard let waiting else { return }
        self.waiting = nil
        readLimit?.cancel()
        let title = webView?.title.flatMap { $0.isEmpty ? nil : $0 }
        if let webView {
            webView.stopLoading()
            webView.pauseAllMediaPlayback()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.configuration.userContentController.removeAllUserScripts()
        }
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
        waiting.resume(returning: PlayedPage(
            title: title, media: found, userAgent: agent, players: rendered.scan.players, scan: rendered.scan.media,
            embeddedJSON: rendered.scan.embeddedJSON, html: rendered.html
        ))
    }

    private func isSameSite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return PageAnalyzer.site(of: url) == PageAnalyzer.site(of: page.url)
    }
}

extension HiddenPlayer: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload || action.targetFrame == nil { return (.cancel, preferences) }
        guard action.targetFrame?.isMainFrame == true, hasLoaded else { return (.allow, preferences) }
        return (isSameSite(action.request.url) ? .allow : .cancel, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasLoaded = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        false
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        nil
    }
}

private final class MessageRelay: NSObject, WKScriptMessageHandler {
    private weak var player: HiddenPlayer?

    init(_ player: HiddenPlayer) {
        self.player = player
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { player?.receive(message.body, from: message.frameInfo) }
    }
}
