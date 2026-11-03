import AppKit
import DowlioConnect
import Foundation
import Observation

final class AddedBrowser: @unchecked Sendable {
    static let remembered: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var added: (name: String, at: Date)?

    func remember(_ name: String) {
        lock.withLock { added = (name, Date()) }
    }

    func name(for reported: String) -> String {
        lock.withLock {
            defer { added = nil }
            guard let added, Date().timeIntervalSince(added.at) < Self.remembered else { return reported }
            return added.name
        }
    }
}

@MainActor
@Observable
final class BrowserSetup {
    private(set) var rows: [BrowserRow] = []
    private(set) var testing: Set<String> = []
    private(set) var isScanning = false
    private(set) var testResults: [String: String] = [:]
    var guide: BrowserRow?
    private(set) var addFailure: String?

    private let server: ConnectServer
    private let added: AddedBrowser
    private let folder: URL

    static var bundled: URL? { Bundle.main.url(forResource: "Dowlio Connect", withExtension: nil) }

    static var bundledVersion: String? { bundled.flatMap(ExtensionFolder.version(at:)) }

    init(server: ConnectServer, added: AddedBrowser, supportFolder: URL) {
        self.server = server
        self.added = added
        folder = supportFolder.appending(path: "Browser Extension", directoryHint: .isDirectory)
        if let bundled = Self.bundled {
            let folder = folder
            Task.detached { _ = try? ExtensionFolder.updateIfOlder(from: bundled, to: folder) }
        }
        Task { await refresh() }
    }

    func reload(_ row: BrowserRow) {
        guard let link = row.link else { return }
        testResults[row.name] = nil
        Task {
            if await !server.reload(link.id) {
                testResults[row.name] = "Dowlio couldn't reach Dowlio Connect in \(row.name). Open \(row.name), then try Reload again."
            }
            await refresh()
        }
    }

    private var installed: [InstalledBrowser]?

    func refresh(rescanning: Bool = false) async {
        if rescanning || installed == nil {
            isScanning = true
            installed = await Task.detached { ChromiumBrowsers.scan() }.value
            isScanning = false
        }
        rows = BrowserList.rows(installed: installed ?? [], links: await server.browserLinks())
    }

    static let otherBrowser = BrowserRow(name: "your browser", appURL: nil, link: nil)

    private var connectedWhenGuideOpened: Set<String> = []

    func add(_ row: BrowserRow) {
        guard prepareExtension() else { return }
        added.remember(row.name)
        guide = row
    }

    func addOther() {
        guard prepareExtension() else { return }
        connectedWhenGuideOpened = Set(rows.filter { $0.state == .connected }.map(\.name))
        guide = Self.otherBrowser
    }

    private func prepareExtension() -> Bool {
        guard let bundled = Self.bundled else {
            addFailure = "Dowlio Connect is missing from this copy of Dowlio. Download Dowlio again."
            return false
        }
        do {
            try ExtensionFolder.install(from: bundled, to: folder)
        } catch {
            addFailure = "Dowlio couldn't put Dowlio Connect in place. \(error.localizedDescription)"
            return false
        }
        addFailure = nil
        return true
    }

    func openExtensionsPage(of row: BrowserRow) {
        guard let appURL = row.appURL, let extensions = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([extensions], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private var newlyConnected: BrowserRow? {
        rows.first { $0.state == .connected && !connectedWhenGuideOpened.contains($0.name) }
    }

    var guideIsConnected: Bool {
        guard let guide else { return false }
        if guide == Self.otherBrowser { return newlyConnected != nil }
        return rows.first { $0.name == guide.name }?.state == .connected
    }

    var guideBrowserName: String {
        guard let guide else { return "" }
        return guide == Self.otherBrowser ? newlyConnected?.name ?? guide.name : guide.name
    }

    func test(_ row: BrowserRow) {
        guard let link = row.link, testing.insert(row.name).inserted else { return }
        testResults[row.name] = nil
        Task {
            let result = await server.test(link.id)
            testing.remove(row.name)
            testResults[row.name] = result.text(browser: row.name)
            await refresh()
        }
    }

    var folderPath: String { folder.path }

    func watch() async {
        for await _ in server.browserChanges {
            await refresh()
        }
    }
}
