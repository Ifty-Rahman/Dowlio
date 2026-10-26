import Foundation

public struct InstalledBrowser: Equatable, Sendable {
    public let name: String
    public let appURL: URL

    public init(name: String, appURL: URL) {
        self.name = name
        self.appURL = appURL
    }
}

public enum ChromiumBrowsers {
    public static var applicationFolders: [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    public static func scan(_ folders: [URL] = applicationFolders) -> [InstalledBrowser] {
        var found: [String: InstalledBrowser] = [:]
        for folder in folders {
            let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" && bundlesChromium(app) {
                let name = app.deletingPathExtension().lastPathComponent
                if found[name] == nil { found[name] = InstalledBrowser(name: name, appURL: app) }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func bundlesChromium(_ app: URL) -> Bool {
        let frameworks = app.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        let name = app.deletingPathExtension().lastPathComponent
        return ["\(name) Framework.framework", "ArcCore.framework"].contains { framework in
            FileManager.default.fileExists(atPath: frameworks.appending(path: framework).path)
        }
    }
}

public enum BrowserState: Equatable, Sendable {
    case connected
    case connecting
    case needsReload
    case notConnected
    case notInstalled
}

public struct BrowserLink: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let state: BrowserState

    public init(id: UUID, name: String, state: BrowserState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public struct BrowserRow: Equatable, Identifiable, Sendable {
    public let name: String
    public let appURL: URL?
    public let link: BrowserLink?

    public var id: String { name }
    public var state: BrowserState { link?.state ?? .notInstalled }
}

public enum BrowserList {
    public static func rows(installed: [InstalledBrowser], links: [BrowserLink]) -> [BrowserRow] {
        var rows = installed.map { BrowserRow(name: $0.name, appURL: $0.appURL, link: bestLink(named: $0.name, in: links)) }
        for link in links where !rows.contains(where: { $0.name.caseInsensitiveCompare(link.name) == .orderedSame }) {
            rows.append(BrowserRow(name: link.name, appURL: nil, link: bestLink(named: link.name, in: links)))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func bestLink(named name: String, in links: [BrowserLink]) -> BrowserLink? {
        let matching = links.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        for state in [BrowserState.connected, .needsReload, .connecting] {
            if let link = matching.first(where: { $0.state == state }) { return link }
        }
        return matching.first
    }
}

public enum LinkTestResult: Equatable, Sendable {
    case passed
    case serverNotListening
    case portInUse
    case notConnected
    case pairingMissing
    case noAnswer
}

extension LinkTestResult {
    public func text(browser: String) -> String {
        switch self {
        case .passed: "Dowlio Connect answered. \(browser) is connected."
        case .serverNotListening: "Dowlio isn't listening for browsers. Quit Dowlio and open it again."
        case .portInUse: "Another app is using Dowlio's ports, 51517 to 51520. Quit that app, then open Dowlio again."
        case .notConnected: "Dowlio Connect in \(browser) isn't connected. Open \(browser), and it connects within 30 seconds."
        case .pairingMissing: "\(browser) isn't paired. Click the Dowlio Connect button in \(browser) to pair it again."
        case .noAnswer: "Dowlio Connect in \(browser) didn't answer within 2 seconds. Open \(browser), then test again."
        }
    }
}

public enum ExtensionVersion {
    public static func isOlder(_ installed: String, than bundled: String) -> Bool {
        let old = parts(installed)
        let new = parts(bundled)
        for index in 0..<max(old.count, new.count) {
            let left = index < old.count ? old[index] : 0
            let right = index < new.count ? new[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}

public enum ExtensionFolder {
    public static func version(at folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest["version"] as? String
    }

    public static func updateIfOlder(from bundled: URL, to destination: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path), let new = version(at: bundled) else { return false }
        guard ExtensionVersion.isOlder(version(at: destination) ?? "0", than: new) else { return false }
        try install(from: bundled, to: destination)
        return true
    }

    public static func install(from bundled: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent)-\(UUID().uuidString)")
        try fileManager.copyItem(at: bundled, to: staged)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }
}
