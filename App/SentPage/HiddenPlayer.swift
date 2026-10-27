import AppKit
import DowlioCore
import DowlioMedia
import WebKit

@MainActor
final class HiddenPlayer: NSObject {
    static let longestPlay: Duration = .seconds(15)
    static let quietAfterMedia: Duration = .seconds(3)
    private static let handlerName = "dowlioMedia"

    static func play(_ page: SentPage) async -> PlayedPage {
        let player = HiddenPlayer(page: page)
        return await withTaskCancellationHandler {
            await player.run()
        } onCancel: {
            Task { @MainActor in player.finish() }
        }
    }

    private let page: SentPage
    private var found: [WatchedRequest] = []
    private var agent: String?
    private var webView: WKWebView?
    private var window: NSWindow?
    private var waiting: CheckedContinuation<PlayedPage, Never>?
    private var deadline: Task<Void, Never>?
    private var quiet: Task<Void, Never>?
    private var hasLoaded = false
    private var isFinished = false

    private init(page: SentPage) {
        self.page = page
    }

    private func run() async -> PlayedPage {
        await withCheckedContinuation { continuation in
            waiting = continuation
            if isFinished { return finish() }
            Task { await start() }
        }
    }

    private func start() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(MessageRelay(self), name: Self.handlerName)
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

    fileprivate func receive(_ body: Any) {
        guard !isFinished, let message = body as? [String: Any] else { return }
        if agent == nil { agent = (message["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let text = message["url"] as? String,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !found.contains(where: { $0.url == url }) else { return }
        let type = (message["type"] as? String).flatMap { $0.isEmpty ? nil : $0.split(separator: ";").first.map(String.init) }
        let isManifest = ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
            || type.map { $0.contains("mpegurl") || $0.contains("dash+xml") } ?? false
        guard isManifest || message["element"] != nil || MediaFile.kind(of: url, contentType: type) != nil else { return }
        let frame = (message["frame"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        found.append(WatchedRequest(url: url, kind: isManifest ? .manifest : .file, contentType: type, referrer: frame ?? page.url))
        guard isManifest || isSameSite(frame ?? page.url) else { return }
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(for: Self.quietAfterMedia)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    fileprivate func finish() {
        isFinished = true
        guard let waiting else { return }
        self.waiting = nil
        deadline?.cancel()
        quiet?.cancel()
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
        waiting.resume(returning: PlayedPage(title: title, media: found, userAgent: agent))
    }

    private func isSameSite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return PageAnalyzer.site(of: url) == PageAnalyzer.site(of: page.url)
    }

    private static let script = """
        (() => {
          if (window.__dowlioWatching) return;
          window.__dowlioWatching = true;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dowlioMedia;
          if (!handler) return;
          const sent = new Set();
          const media = /\\.(m3u8|mpd|mp4|m4v|mov|webm|m4a|mp3|aac)(\\?|#|$)/i;
          const send = (value, type, element) => {
            let url;
            try { url = new URL(String(value), location.href).href; } catch (e) { return; }
            if (!/^https?:/i.test(url)) return;
            const key = url + '|' + (type || '');
            if (sent.has(key)) return;
            sent.add(key);
            const message = { url, type: type || '', frame: location.href, agent: navigator.userAgent };
            if (element) message.element = true;
            handler.postMessage(message);
          };
          const check = (value) => { if (typeof value === 'string' && media.test(value.split('#')[0])) send(value); };
          const isMediaType = (type) => /mpegurl|dash\\+xml|^video\\/|^audio\\//i.test(type || '');
          const open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            check(String(url));
            this.addEventListener('load', () => {
              const type = this.getResponseHeader('content-type');
              if (isMediaType(type)) send(this.responseURL, type);
            });
            return open.apply(this, arguments);
          };
          const originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function (input) {
              const url = typeof input === 'string' ? input : (input && input.url) || String(input);
              check(url);
              return originalFetch.apply(this, arguments).then((response) => {
                const type = response.headers && response.headers.get('content-type');
                if (isMediaType(type)) send(response.url || url, type);
                return response;
              });
            };
          }
          try {
            new PerformanceObserver((list) => list.getEntries().forEach((entry) => check(entry.name)))
              .observe({ type: 'resource', buffered: true });
          } catch (e) {}
          const originalPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function () {
            this.muted = true;
            return originalPlay.apply(this, arguments);
          };
          const play = () => {
            document.querySelectorAll('video, audio').forEach((element) => {
              element.muted = true;
              element.volume = 0;
              const source = element.currentSrc || element.src;
              if (source && !source.startsWith('blob:')) send(source, '', true);
              element.querySelectorAll('source[src]').forEach((child) => send(child.src, child.type, true));
            });
            try {
              if (typeof window.jwplayer === 'function') {
                const playlist = window.jwplayer().getPlaylist() || [];
                playlist.forEach((item) => {
                  check(item.file);
                  (item.sources || []).forEach((source) => check(source.file));
                });
              }
            } catch (e) {}
            const first = document.querySelector('video');
            if (first && first.paused) {
              const started = first.play();
              if (started && started.catch) started.catch(() => {});
            }
          };
          const pressPlay = () => {
            if (window === window.top || innerWidth < 400 || innerHeight < 220) return;
            if (sent.size > 0) return;
            const target = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
            if (target) target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
          };
          document.addEventListener('DOMContentLoaded', play);
          setInterval(play, 500);
          [1500, 2500, 3500].forEach((delay) => setTimeout(pressPlay, delay));
        })();
        """
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
        MainActor.assumeIsolated { player?.receive(message.body) }
    }
}
