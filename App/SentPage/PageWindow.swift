import AppKit
import DowlioCore
import DowlioLibrary
import DowlioMedia
import Observation
import SwiftUI
import WebKit

@MainActor
enum PageWindows {
    private static var open: [PageWindowModel] = []

    static func open(
        _ page: SentPage, read: @escaping (PlayedPage, SentPage) async -> PageAnalysis, choose: @escaping (SentPage, Candidate) -> Void
    ) {
        let model = PageWindowModel(page: page, read: read, choose: choose)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.title = model.windowTitle
        window.contentView = NSHostingView(rootView: PageWindowView(model: model))
        window.center()
        model.window = window
        model.onClose = { closed in open.removeAll { $0 === closed } }
        window.delegate = model
        open.append(model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.start()
    }
}

@MainActor
@Observable
final class PageWindowModel: NSObject {
    enum Reading: Equatable {
        case watching
        case needsSignIn
        case blocked
    }

    let page: SentPage
    let webView: WKWebView
    var address: String
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var candidates: [Candidate] = []
    var reading = Reading.watching
    var allowsPopUpsAndDownloads = false
    var refusedNote: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var onClose: ((PageWindowModel) -> Void)?
    @ObservationIgnored private let read: (PlayedPage, SentPage) async -> PageAnalysis
    @ObservationIgnored private let choose: (SentPage, Candidate) -> Void
    @ObservationIgnored private var found: [WatchedRequest] = []
    @ObservationIgnored private var frames: [WKFrameInfo] = []
    @ObservationIgnored private var agent: String?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    static let settleTime: Duration = .milliseconds(800)

    init(page: SentPage, read: @escaping (PlayedPage, SentPage) async -> PageAnalysis, choose: @escaping (SentPage, Candidate) -> Void) {
        self.page = page
        self.read = read
        self.choose = choose
        address = page.url.absoluteString
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: PageWatcher.passiveScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        for script in PageWatcher.userScripts() { configuration.userContentController.addUserScript(script) }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = page.userAgent
        super.init()
        configuration.userContentController.add(WindowRelay(self), name: PageWatcher.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let url = view.url { self?.address = url.absoluteString } }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let title = view.title, !title.isEmpty { self?.window?.title = title } }
            },
        ]
    }

    var windowTitle: String { page.title ?? page.url.host(percentEncoded: false) ?? "Dowlio" }

    func start() {
        webView.load(URLRequest(url: page.url))
    }

    func go(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func add(_ candidate: Candidate) {
        Task { [weak self] in
            guard let self else { return }
            choose(await sentPage(), candidate)
        }
    }

    fileprivate func receive(_ body: Any, from frame: WKFrameInfo) {
        guard let message = body as? [String: Any] else { return }
        if message["scanReady"] != nil {
            if frames.count < PageWatcher.framesRead { frames.append(frame) }
            return scheduleRefresh()
        }
        if agent == nil { agent = PageWatcher.agent(in: message) }
        guard let url = webView.url, let request = PageWatcher.request(from: message, on: url),
              !found.contains(where: { $0.url == request.url }) else { return }
        found.append(request)
        scheduleRefresh()
    }

    fileprivate func startedPage() {
        refresh?.cancel()
        found = []
        frames = []
        candidates = []
        reading = .watching
        refusedNote = nil
    }

    fileprivate func scheduleRefresh() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            try? await Task.sleep(for: Self.settleTime)
            guard !Task.isCancelled else { return }
            await self?.readPage()
        }
    }

    private func sentPage() async -> SentPage {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = webView.url?.host(percentEncoded: false) ?? page.url.host(percentEncoded: false) ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        return SentPage(
            url: webView.url ?? page.url, title: webView.title, cookies: matching.map { Cookie(name: $0.name, value: $0.value) },
            userAgent: page.userAgent ?? agent
        )
    }

    private func readPage() async {
        let rendered = await PageWatcher.render(webView, frames: frames)
        guard !Task.isCancelled else { return }
        let played = PlayedPage(
            title: webView.title, media: found, userAgent: agent, players: rendered.scan.players, scan: rendered.scan.media,
            embeddedJSON: rendered.scan.embeddedJSON, html: rendered.html
        )
        let analysis = await read(played, await sentPage())
        guard !Task.isCancelled else { return }
        switch analysis {
        case .found(let candidates):
            self.candidates = candidates
            reading = .watching
        case .needsSignIn:
            reading = .needsSignIn
        case .blocked:
            reading = .blocked
        case .looking, .checkingForMore, .playing, .plainFile:
            break
        }
    }

    fileprivate func refuse(_ what: String) {
        refusedNote = what
    }
}

extension PageWindowModel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        refresh?.cancel()
        webView.stopLoading()
        webView.pauseAllMediaPlayback()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        onClose?(self)
    }
}

extension PageWindowModel: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload {
            guard allowsPopUpsAndDownloads, let url = action.request.url else {
                refuse("Blocked a file download. Allow pop-ups and downloads to take it.")
                return (.cancel, preferences)
            }
            handOver(url)
            return (.cancel, preferences)
        }
        if action.targetFrame == nil, action.navigationType == .linkActivated, let url = action.request.url {
            webView.load(URLRequest(url: url))
            return (.cancel, preferences)
        }
        if action.targetFrame == nil {
            guard allowsPopUpsAndDownloads, let url = action.request.url else {
                refuse("Blocked a pop-up. Allow pop-ups and downloads to open it.")
                return (.cancel, preferences)
            }
            webView.load(URLRequest(url: url))
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !response.canShowMIMEType, response.isForMainFrame else { return .allow }
        guard allowsPopUpsAndDownloads, let url = response.response.url else {
            refuse("Blocked a file download. Allow pop-ups and downloads to take it.")
            return .cancel
        }
        handOver(url)
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if allowsPopUpsAndDownloads, let url = action.request.url {
            webView.load(URLRequest(url: url))
        } else {
            refuse("Blocked a pop-up. Allow pop-ups and downloads to open it.")
        }
        return nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        startedPage()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleRefresh()
    }

    private func handOver(_ url: URL) {
        AppDelegate.model?.requestNewDownload(url.absoluteString)
    }
}

private final class WindowRelay: NSObject, WKScriptMessageHandler {
    private weak var model: PageWindowModel?

    init(_ model: PageWindowModel) {
        self.model = model
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { model?.receive(message.body, from: message.frameInfo) }
    }
}

struct PageWindowView: View {
    @Bindable var model: PageWindowModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                PageWebView(webView: model.webView)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                sidebar
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: DowlioDesign.Spacing.sm) {
            Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back")
            Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward")
            Button { model.reloadOrStop() } label: { Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise") }
                .help(model.isLoading ? "Stop" : "Reload")
            TextField("Address", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.go(to: model.address) }
            Toggle("Allow pop-ups and downloads", isOn: $model.allowsPopUpsAndDownloads)
                .toggleStyle(.checkbox)
        }
        .padding(DowlioDesign.Spacing.sm)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DowlioDesign.Spacing.sm) {
            Text("Found on this page").font(DowlioDesign.TypeRole.heading)
            if let note = model.refusedNote {
                Text(note).font(DowlioDesign.TypeRole.detail).foregroundStyle(.orange)
            }
            switch model.reading {
            case .needsSignIn where model.candidates.isEmpty:
                note("This site only shows this video to signed-in visitors. Sign in on the page.")
            case .blocked where model.candidates.isEmpty:
                note("This page wants to check you're a person. Finish the check on the page.")
            default:
                if model.candidates.isEmpty {
                    note("Play the video or sign in on the page. What Dowlio sees will show up here.")
                } else {
                    ScrollView {
                        VStack(spacing: DowlioDesign.Spacing.sm) {
                            ForEach(Array(model.candidates.enumerated()), id: \.offset) { _, candidate in
                                FoundRow(candidate: candidate) { model.add(candidate) }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DowlioDesign.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DowlioDesign.TypeRole.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FoundRow: View {
    let candidate: Candidate
    let add: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DowlioDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                Text(candidate.label).font(DowlioDesign.TypeRole.body).lineLimit(2)
                Text(restrictionOrSummary).font(DowlioDesign.TypeRole.detail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Add", action: add)
                .disabled(candidate.restriction != nil)
        }
        .padding(DowlioDesign.Spacing.sm)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
    }

    private var restrictionOrSummary: String {
        switch candidate.restriction {
        case .protected: "Protected, can't be downloaded"
        case .live: "Live stream, not supported yet"
        case .needsPassword: "Needs a password"
        case nil: MediaText.summary(of: candidate)
        }
    }
}

private struct PageWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct OpenInWindowButton: View {
    let media: SentPageModel

    var body: some View {
        Button("Open in a Dowlio window") { AppDelegate.model?.openPageWindow(for: media.draft.page) }
    }
}
