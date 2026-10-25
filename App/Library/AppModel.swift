import AppKit
import DowlioConnect
import DowlioCore
import DowlioEngine
import DowlioLibrary
import DowlioStore
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var rows: [DownloadRow] = []
    private(set) var problem: String?
    /// A failed action to tell the user about, such as a file the Trash refused.
    var actionFailure: String?
    /// The New Download sheet, made once each time it's asked for and dropped when it closes.
    var newDownload: NewDownloadModel?
    /// Opens the library window. The window hands it over the first time it appears, so a link
    /// that arrives while it's closed can open it again.
    var openLibraryWindow: (() -> Void)?

    var settings: DownloadSettings { Self.currentSettings() }

    nonisolated static func currentSettings() -> DownloadSettings {
        var settings = UserDefaults.standard.downloadSettings
        if let folder = DebugLaunch.downloadsFolder { settings.folder = folder }
        return settings
    }

    var downloadsFolder: URL { settings.folder }

    /// The library window, kept so Open Dowlio can bring it back even when it has never shown,
    /// as after a quiet start at login.
    weak var libraryWindow: NSWindow?
    weak var menuBar: MenuBarController?
    private let notifier = FinishNotifier()
    private let catchNotifier = CatchNotifier()
    private var catchGrouper = CatchGrouper()
    var revealing: [DownloadID]?
    var catchPreferences = UserDefaults.standard.catchPreferences {
        didSet {
            guard catchPreferences != oldValue else { return }
            UserDefaults.standard.catchPreferences = catchPreferences
            preferenceUpdates.continuation.yield(catchPreferences)
        }
    }
    private let preferenceUpdates = AsyncStream<CatchPreferences>.makeStream()
    private(set) var freeSpace: Int64?

    private let library: Library?
    private var connectServer: ConnectServer?

    init() {
        do {
            let support = try DebugLaunch.supportFolder ?? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appending(path: AppIdentity.supportFolderName, directoryHint: .isDirectory)
            let store = try DownloadStore(databaseAt: support.appending(path: "Dowlio.sqlite"))
            let library = Library(engine: DownloadEngine(), store: store)
            self.library = library
            startConnectServer(store: store, library: library, support: support)
        } catch {
            library = nil
            problem = "Dowlio can't open its history: \(error.localizedDescription)"
            return
        }
        Task { await follow() }
        DebugLaunch.addLinks { [weak self] links in
            guard let self else { return }
            var draft = NewDownloadDraft(text: links, folder: downloadsFolder)
            draft.startImmediately = true
            add(draft)
        }
        DebugLaunch.useSheet { [weak self] links in
            self?.requestNewDownload(links)
        } download: { [weak self] in
            guard let self, let sheet = newDownload else { return }
            add(sheet.draft)
            newDownload = nil
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.perform { await $0.checkFinishedFiles() }
                self?.measureFreeSpace()
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.measureFreeSpace()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private(set) var browserSetup: BrowserSetup?

    private func startConnectServer(store: DownloadStore, library: Library, support: URL) {
        let added = AddedBrowser()
        let catcher = Catcher(library: library, settings: { AppModel.currentSettings() })
        let vault = KeychainTokenVault(service: AppIdentity.bundleIdentifier + ".connect")
        let server = ConnectServer(
            store: store, vault: vault, catcher: catcher, preferences: catchPreferences,
            nameBrowser: { added.name(for: $0) }
        ) { request in
            await MainActor.run { PairingAlert.ask(request) }
        }
        connectServer = server
        browserSetup = BrowserSetup(server: server, added: added, supportFolder: support)
        Task { _ = try? await server.start() }
        Task { [weak self] in
            for await caught in server.catches {
                self?.announce(caught)
            }
        }
        Task { [weak self] in
            for await change in server.preferenceChanges {
                guard let self else { return }
                catchPreferences = change.applied(to: catchPreferences)
            }
        }
        Task { [weak self] in
            for await link in server.sentLinks {
                self?.receive(link)
            }
        }
        Task { [weak self] in
            for await grant in server.signInGrants {
                self?.grant(grant)
            }
        }
        Task { [weak self] in
            for await sites in server.allowedSites {
                self?.allowedSignInSites = sites
            }
        }
        let updates = preferenceUpdates.stream
        Task {
            for await preferences in updates {
                await server.publish(preferences)
            }
        }
    }

    private func announce(_ caught: CaughtDownload) {
        notifier.askPermissionIfNeeded()
        let notice = catchGrouper.add(caught, at: Date())
        if let menuBar, menuBar.isVisible {
            menuBar.showCatch(notice)
        } else {
            catchNotifier.post(notice)
        }
    }

    private(set) var allowedSignInSites: [URL] = []
    private var recentlySent: [URL: SentLink] = [:]
    private var askedForSignIn: Set<URL> = []

    private func askForSignIn(_ url: URL) {
        guard let sent = recentlySent[url], let connectServer, askedForSignIn.insert(url).inserted else { return }
        Task { _ = await connectServer.askForSignIn(sent) }
    }

    private func grant(_ grant: SignInGrant) {
        menuBar?.grantSignIn(grant)
        newDownload?.draft.grantSignIn(origin: grant.origin, cookies: grant.cookies)
        askedForSignIn = askedForSignIn.filter { $0.host() != grant.origin.host() }
    }

    func revokeSignIn(_ site: URL) {
        guard let connectServer else { return }
        Task { await connectServer.revokeSignIn(site) }
    }

    private func receive(_ link: SentLink) {
        recentlySent[link.url] = link
        if recentlySent.count > 50 { recentlySent.removeValue(forKey: recentlySent.keys.first!) }
        let menuBarShown = menuBar?.isVisible ?? false
        switch NewLinkRoute(entry: .sentFromBrowser, windowIsOpen: isLibraryWindowOpen, menuBarShown: menuBarShown) {
        case .quickAdd:
            menuBar?.showSent(link)
        case .sheet, .openWindowThenSheet:
            showLibraryWindow()
            if newDownload == nil { newDownload = makeNewDownload() }
            newDownload?.draft.addSent(link.url, referrer: link.referrer, cookies: link.cookies, browser: link.browser)
        }
    }

    func downloadInBrowser(_ notice: CatchNotice) {
        guard let caught = notice.single, let connectServer else { return }
        Task {
            guard await !connectServer.downloadInBrowser(caught) else { return }
            actionFailure = "Dowlio kept “\(caught.fileName)”, because no browser with Dowlio Connect is connected."
            showLibraryWindow()
        }
    }

    func show(_ notice: CatchNotice) {
        revealing = notice.downloads.map(\.id)
        showLibraryWindow()
    }

    func answerCatchNotification(_ identifier: String, action: CatchNotifier.Action) {
        guard let notice = catchNotifier.notice(identifier) else { return showLibraryWindow() }
        switch action {
        case .downloadInBrowser: downloadInBrowser(notice)
        case .show: show(notice)
        }
    }

    func row(_ id: DownloadID) -> DownloadRow? {
        rows.first { $0.id == id }
    }

    /// Shows the New Download sheet with `text` in its link field, opening the window first. With
    /// the sheet already up, the links join it.
    func requestNewDownload(_ text: String = "") {
        showLibraryWindow()
        if let newDownload {
            newDownload.append(text)
        } else {
            newDownload = makeNewDownload(text)
        }
    }

    func continueInWindow(_ quickAdd: NewDownloadModel) {
        showLibraryWindow()
        if let newDownload {
            newDownload.draft.merge(quickAdd.draft)
        } else {
            newDownload = quickAdd
        }
    }

    /// A draft for the New Download sheet or Quick add, checking links through the library.
    func makeNewDownload(_ text: String = "") -> NewDownloadModel? {
        guard let library else { return nil }
        let model = NewDownloadModel(text: text, folder: downloadsFolder) { url, options in
            try await library.inspect(url, options: options)
        }
        model.needsSignIn = { [weak self] url in self?.askForSignIn(url) }
        model.draft.connections = settings.connections
        return model
    }

    var isLibraryWindowOpen = false

    func showLibraryWindow() {
        NSApp.activate()
        if let libraryWindow, libraryWindow.isVisible || libraryWindow.isMiniaturized {
            libraryWindow.makeKeyAndOrderFront(nil)
        } else if let libraryWindow, openLibraryWindow == nil {
            libraryWindow.makeKeyAndOrderFront(nil)
        } else {
            openLibraryWindow?()
        }
    }

    /// Shows Dowlio in the Dock, the menu bar or both, as Settings › General says. A start at login
    /// doesn't take focus.
    func applyPresence(activating: Bool = true) {
        let presence = UserDefaults.standard.presence
        menuBar?.isVisible = presence.menuBar
        NSApp.setActivationPolicy(presence.dock ? .regular : .accessory)
        if activating { NSApp.activate() }
    }

    func applyDownloadsAtOnce() {
        let limit = settings.downloadsAtOnce
        perform { await $0.setMaximumActive(limit) }
    }

    /// Pauses everything, so every partial file has its latest manifest before Dowlio quits.
    func stopForQuit() async {
        await library?.pauseAll()
    }

    /// SwiftUI's own way to open Settings, handed over by the library window.
    var openSettingsWindow: (() -> Void)?

    func showSettings() {
        NSApp.activate()
        openSettingsWindow?()
    }

    func reportProblem() {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        NSWorkspace.shared.open(ProblemReport.url(appVersion: app, macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
    }

    func add(_ draft: NewDownloadDraft) {
        notifier.askPermissionIfNeeded()
        let settings = settings
        let destination = settings.destination(in: draft.folder)
        let added = draft.links.map { url in
            let chosen = draft.options(for: url)
            var options = settings.options(connections: chosen.connections)
            options.referrer = chosen.referrer
            options.userAgent = chosen.userAgent
            options.fileName = chosen.fileName
            options.cookies = chosen.cookies
            return (url, options, draft.origin(for: url))
        }
        perform { library in
            for (url, options, origin) in added {
                await library.add(url, destination: destination, options: options, startImmediately: draft.startImmediately, origin: origin)
            }
        }
    }

    func pause(_ row: DownloadRow) { perform { await $0.pause(row.id) } }
    func resume(_ row: DownloadRow) { perform { await $0.resume(row.id) } }
    func retry(_ row: DownloadRow) { perform { await $0.retry(row.id) } }
    func cancel(_ row: DownloadRow) { perform { await $0.cancel(row.id) } }
    func removeFromList(_ row: DownloadRow) { perform { await $0.removeFromList(row.id) } }
    func clearCompleted() { perform { await $0.clearCompleted() } }
    func pauseAll() { perform { await $0.pauseAll() } }
    func resumeAll() { perform { await $0.resumeAll() } }

    private func measureFreeSpace() {
        let values = try? downloadsFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeSpace = values?.volumeAvailableCapacityForImportantUsage
    }

    func moveToTrash(_ row: DownloadRow) {
        perform { [weak self] library in
            do {
                try await library.moveToTrash(row.id)
            } catch {
                self?.actionFailure = "Dowlio couldn't move “\(row.fileName)” to the Trash. \(error.localizedDescription)"
            }
        }
    }

    func showInFinder(_ row: DownloadRow) {
        guard let file = row.finishedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func open(_ row: DownloadRow) {
        guard let file = row.finishedFile else { return }
        NSWorkspace.shared.open(file)
    }

    func copyLink(_ row: DownloadRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.sourceURL.absoluteString, forType: .string)
    }

    private func perform(_ work: @escaping @MainActor (Library) async -> Void) {
        guard let library else { return }
        Task { await work(library) }
    }

    private func follow() async {
        guard let library else { return }
        await library.start(maximumFailures: settings.maximumFailures, allowsWorkStealing: settings.takesOverSlowSegments)
        await library.setMaximumActive(settings.downloadsAtOnce)
        for await rows in await library.rows() {
            self.rows = rows
            notifier.update(rows)
        }
    }
}
