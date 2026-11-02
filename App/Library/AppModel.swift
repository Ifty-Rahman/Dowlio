import AppKit
import DowlioConnect
import DowlioCore
import DowlioEngine
import DowlioLibrary
import DowlioMedia
import DowlioStore
import KeyboardShortcuts
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
    private let hostCooldown = HostCooldown()
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
        UserDefaults.standard.removeRetiredSettings()
        do {
            let support = try DebugLaunch.supportFolder ?? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appending(path: AppIdentity.supportFolderName, directoryHint: .isDirectory)
            let store = try DownloadStore(databaseAt: support.appending(path: "Dowlio.sqlite"))
            let library = Library(engine: DownloadEngine(remux: AVRemuxer.remux, identity: { WebKitIdentity.shared.current }), store: store)
            self.library = library
            startConnectServer(store: store, library: library, support: support)
        } catch {
            library = nil
            problem = "Dowlio can't open its history: \(error.localizedDescription)"
            return
        }
        Task { await follow() }
        Task { await WebKitIdentity.shared.read() }
        KeyboardShortcuts.onKeyDown(for: .sendPage) { [weak self] in self?.sendFrontPage() }
        DebugLaunch.addLinks { [weak self] links in
            guard let self else { return }
            var draft = NewDownloadDraft(text: links, folder: downloadsFolder)
            draft.startImmediately = true
            add(draft)
        }
        DebugLaunch.sendPage { [weak self] page in
            self?.receive(page)
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
            nameBrowser: { added.name(for: $0) }, extensionVersion: BrowserSetup.bundledVersion
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
            for await page in server.sentPages {
                self?.receive(page)
            }
        }
        let updates = preferenceUpdates.stream
        Task {
            for await preferences in updates {
                await server.publish(preferences)
            }
        }
    }

    func sendFrontPage() {
        let server = connectServer
        let app = FrontBrowser.frontApp
        let target = sendTarget(activating: false)
        let ask = target?.askFrontPage(of: app?.name ?? "the browser")
        Task { [weak self, weak target] in
            let outcome = await FrontPage.read(app, scan: { await server?.scanPage(in: $0) ?? .notConnected }, appleEvents: { await FrontBrowser.read($0) })
            switch outcome {
            case .sentThroughConnect:
                break
            case .read(let page):
                self?.receive(page)
            case .couldntRead(let reason):
                if let ask { target?.couldntRead(reason, asked: ask) }
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

    private func receive(_ link: SentLink) {
        switch sentRoute {
        case .quickAdd:
            menuBar?.showSent(link)
        case .sheet, .openWindowThenSheet:
            sentSheet()?.addSent(link)
        }
    }

    private func receive(_ page: SentPage) {
        sendTarget()?.analyze(page)
    }

    private func sendTarget(activating: Bool = true) -> NewDownloadModel? {
        switch sentRoute {
        case .quickAdd: menuBar?.sendTarget(activating: activating)
        case .sheet, .openWindowThenSheet: sentSheet()
        }
    }

    private func sentSheet() -> NewDownloadModel? {
        if let newDownload { return newDownload }
        showLibraryWindow()
        newDownload = makeNewDownload()
        return newDownload
    }

    private var sentRoute: NewLinkRoute {
        NewLinkRoute(entry: .sentFromBrowser, windowIsOpen: isLibraryWindowOpen, menuBarShown: menuBar?.isVisible ?? false)
    }

    func analyze(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        recorded(page) { $0.analyze(page) }
    }

    func lookAgain(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        recorded(page) { $0.lookAgain(page) }
    }

    func probe(_ page: SentPage, _ candidate: Candidate) async -> Candidate {
        guard let analyzer else { return candidate }
        return await analyzer.probe(candidate, on: page)
    }

    private var analyzer: PageAnalyzer? {
        guard let library else { return nil }
        #if DEBUG
        let readerFailed: @Sendable (ReaderFailure) -> Void = { ReaderFailure.log($0); SentPageRecord.note($0) }
        #else
        let readerFailed = ReaderFailure.log
        #endif
        return PageAnalyzer(identity: WebKitIdentity.shared.current, cooldown: hostCooldown, lookAgain: { await HiddenPlayer.play($0) }, readerFailed: readerFailed) { url, options in
            try await library.inspect(url, options: options)
        }
    }

    private func recorded(_ page: SentPage, _ run: (PageAnalyzer) -> AsyncStream<PageAnalysis>) -> AsyncStream<PageAnalysis> {
        guard let analyzer else { return .nothingFound }
        #if DEBUG
        return SentPageRecord.recording(page, run(analyzer))
        #else
        return run(analyzer)
        #endif
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
        if let newDownload, !quickAdd.list.hasPages {
            newDownload.draft.merge(quickAdd.draft)
        } else {
            newDownload?.discardSentPage()
            newDownload = quickAdd
        }
    }

    /// A draft for the New Download sheet or Quick add, checking links through the library.
    func makeNewDownload(_ text: String = "") -> NewDownloadModel? {
        guard let library else { return nil }
        let list = LinkList(analyze: analyze, lookAgain: lookAgain, probe: probe) { AppModel.currentSettings().qualityPreference }
        let model = NewDownloadModel(text: text, folder: downloadsFolder, list: list, inspect: { url, options in
            try await library.inspect(url, options: options)
        }, signIn: { [weak self] url in
            guard UserDefaults.standard.bool(forKey: SettingsKey.usesBrowserSignIn) else { return nil }
            return await self?.connectServer?.signIn(for: url, frontBrowser: FrontBrowser.frontApp?.name)
        })
        model.draft.connections = settings.connections
        return model
    }

    var isLibraryWindowOpen = false

    private var lastFocusMove: Date?

    func movedFocus(since date: Date) -> Bool {
        lastFocusMove.map { $0 >= date } ?? false
    }

    func showLibraryWindow() {
        lastFocusMove = Date()
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
        lastFocusMove = Date()
        NSApp.activate()
        openSettingsWindow?()
    }

    func reportProblem() {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        NSWorkspace.shared.open(ProblemReport.url(appVersion: app, macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
    }

    func addList(_ sheet: NewDownloadModel) {
        notifier.askPermissionIfNeeded()
        let settings = settings
        let draft = sheet.draft
        let list = sheet.list
        let destination = settings.destination(in: draft.folder)
        if sheet.makesDefaultQuality, let shown = list.current, let height = list.chosenVersion(of: shown.id)?.height {
            UserDefaults.standard.setVideoQualityCap(height)
        }
        let isTaken = Self.nameIsTaken(in: draft.folder)
        let addsResolution = settings.nameConflictPolicy == .keepBoth
        let added = list.downloads.map { download -> (DownloadSource, RequestOptions, DownloadOrigin?) in
            switch download {
            case let .media(page, candidate, version, name):
                let chosen = draft.options(for: page.url)
                var options = settings.options(connections: chosen.connections)
                options.referrer = chosen.referrer ?? version.referrer ?? page.url
                options.origin = version.origin
                options.userAgent = chosen.userAgent ?? version.userAgent ?? page.userAgent
                options.cookies = chosen.cookies.isEmpty ? page.cookies : chosen.cookies
                options.fileName = name ?? MediaNaming.fileName(label: candidate.label, version: version, addsResolution: addsResolution, isTaken: isTaken)
                return (version.source, options, draft.origin(for: page.url))
            case let .file(url, name):
                let chosen = draft.options(for: url)
                var options = settings.options(connections: chosen.connections)
                options.referrer = chosen.referrer
                options.userAgent = chosen.userAgent
                options.cookies = chosen.cookies
                options.fileName = name
                return (.file(url), options, draft.origin(for: url))
            }
        }
        perform { library in
            for (source, options, origin) in added {
                await library.add(source, destination: destination, options: options, startImmediately: draft.startImmediately, origin: origin)
            }
        }
    }

    nonisolated static func nameIsTaken(in folder: URL) -> (String) -> Bool {
        let folders = [folder] + [FileCategory.video, .audio].map { folder.appending(path: $0.folderName, directoryHint: .isDirectory) }
        return { name in folders.contains { FileManager.default.fileExists(atPath: $0.appending(path: name).path) } }
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
        lastFocusMove = Date()
        guard let file = row.finishedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func open(_ row: DownloadRow) {
        lastFocusMove = Date()
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
