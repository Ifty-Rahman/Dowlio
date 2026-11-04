import CryptoKit
import Foundation
import os

public enum Tool: String, Codable, CaseIterable, Sendable {
    case ytdlp = "yt-dlp"
    case quickJS = "qjs"

    var repository: String {
        switch self {
        case .ytdlp: "yt-dlp/yt-dlp"
        case .quickJS: "quickjs-ng/quickjs"
        }
    }

    var assetName: String {
        switch self {
        case .ytdlp: "yt-dlp_macos.zip"
        case .quickJS: Self.quickJSAsset
        }
    }

    private static var quickJSAsset: String {
        #if arch(arm64)
        "qjs-darwin-arm64"
        #else
        "qjs-darwin-x86_64"
        #endif
    }

    public var name: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .quickJS: "QuickJS-NG"
        }
    }

    public var project: URL {
        URL(string: "https://github.com/\(repository)")!
    }
}

public struct ToolLocations: Equatable, Sendable {
    public var ytdlp: URL
    public var quickJS: URL
}

public struct GitHubSource: Sendable {
    let api: URL
    let hosts: Set<String>
    let requiresHTTPS: Bool

    public static let official = GitHubSource(
        api: URL(string: "https://api.github.com")!,
        hosts: ["api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"],
        requiresHTTPS: true
    )

    public static func testing(api: URL) -> GitHubSource {
        GitHubSource(api: api, hosts: [api.host(percentEncoded: false) ?? ""], requiresHTTPS: false)
    }

    func allows(_ url: URL?) -> Bool {
        guard let url, let host = url.host(percentEncoded: false)?.lowercased(), hosts.contains(host) else { return false }
        return url.scheme?.lowercased() == "https" || (!requiresHTTPS && url.scheme?.lowercased() == "http")
    }
}

public actor ToolInstaller {
    public enum Failure: Error, Equatable, Sendable {
        case notInstalled
        case changed(Tool)
        case hashMismatch(Tool)
        case notStable(Tool)
        case missingAsset(Tool)
        case offGitHub
        case network
        case couldNotInstall(Tool)
    }

    struct Record: Codable, Equatable {
        var version: String
        var sha256: String
    }

    private static let logger = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "tools")

    public let folder: URL
    private let source: GitHubSource
    private let session: URLSession

    public init(folder: URL, source: GitHubSource = .official, session: URLSession = PageAnalyzer.makeSession()) {
        self.folder = folder
        self.source = source
        self.session = session
    }

    public static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Dowlio/Tools", directoryHint: .isDirectory)
    }

    private var recordsURL: URL { folder.appending(path: "tools.json") }

    private func location(of tool: Tool) -> URL {
        switch tool {
        case .ytdlp: folder.appending(path: "yt-dlp/yt-dlp_macos")
        case .quickJS: folder.appending(path: "qjs")
        }
    }

    private func installedItem(of tool: Tool) -> URL {
        switch tool {
        case .ytdlp: folder.appending(path: "yt-dlp", directoryHint: .isDirectory)
        case .quickJS: folder.appending(path: "qjs")
        }
    }

    private func records() -> [Tool: Record] {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Tool(rawValue: key).map { ($0, value) } })
    }

    private func save(_ records: [Tool: Record]) throws {
        let encoded = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        try JSONEncoder().encode(encoded).write(to: recordsURL, options: .atomic)
    }

    public var isInstalled: Bool {
        let known = records()
        return Tool.allCases.allSatisfy { known[$0] != nil && FileManager.default.fileExists(atPath: location(of: $0).path) }
    }

    public func installedVersions() -> [Tool: String] {
        records().mapValues(\.version)
    }

    public func verifiedTools() throws -> ToolLocations {
        let known = records()
        guard Tool.allCases.allSatisfy({ known[$0] != nil }) else { throw Failure.notInstalled }
        for tool in Tool.allCases {
            guard let record = known[tool], let hash = try? Self.hash(of: installedItem(of: tool)), hash == record.sha256 else {
                throw Failure.changed(tool)
            }
        }
        return ToolLocations(ytdlp: location(of: .ytdlp), quickJS: location(of: .quickJS))
    }

    public func downloadSize() async throws -> Int64 {
        var total: Int64 = 0
        for tool in Tool.allCases {
            let release = try await latestRelease(of: tool)
            guard let asset = release.assets.first(where: { $0.name == tool.assetName }) else { throw Failure.missingAsset(tool) }
            total += asset.size
        }
        return total
    }

    public func install() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var staged: [(Tool, URL, Record)] = []
        defer { staged.forEach { try? FileManager.default.removeItem(at: $0.1) } }
        for tool in Tool.allCases {
            let release = try await latestRelease(of: tool)
            staged.append(try await stage(tool, from: release))
        }
        var known = records()
        for (tool, item, record) in staged {
            try replace(installedItem(of: tool), with: item)
            known[tool] = record
        }
        try save(known)
        Self.logger.info("Installed yt-dlp \(known[.ytdlp]?.version ?? "?", privacy: .public) and QuickJS-NG \(known[.quickJS]?.version ?? "?", privacy: .public)")
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var size: Int64
            var browserDownloadURL: URL
            var digest: String?

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        var tagName: String
        var prerelease: Bool
        var draft: Bool
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case prerelease, draft, assets
            case tagName = "tag_name"
        }
    }

    private func latestRelease(of tool: Tool) async throws -> Release {
        let url = source.api.appending(path: "repos/\(tool.repository)/releases/latest")
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try await fetch(request)
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw Failure.network }
        guard !release.prerelease, !release.draft else { throw Failure.notStable(tool) }
        return release
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        guard source.allows(request.url) else { throw Failure.offGitHub }
        let guardian = RedirectGuard(source: source)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: guardian)
        } catch {
            if guardian.refused { throw Failure.offGitHub }
            throw Failure.network
        }
        if guardian.refused { throw Failure.offGitHub }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure.network }
        return data
    }

    private func download(_ url: URL) async throws -> URL {
        guard source.allows(url) else { throw Failure.offGitHub }
        let guardian = RedirectGuard(source: source)
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(for: URLRequest(url: url), delegate: guardian)
        } catch {
            if guardian.refused { throw Failure.offGitHub }
            throw Failure.network
        }
        guard !guardian.refused, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw guardian.refused ? Failure.offGitHub : Failure.network
        }
        let kept = folder.appending(path: ".download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    private func stage(_ tool: Tool, from release: Release) async throws -> (Tool, URL, Record) {
        guard let asset = release.assets.first(where: { $0.name == tool.assetName }) else { throw Failure.missingAsset(tool) }
        let expected = try await expectedHash(of: tool, asset: asset, in: release)
        let downloaded = try await download(asset.browserDownloadURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard try Self.fileHash(downloaded) == expected else { throw Failure.hashMismatch(tool) }
        let item = folder.appending(path: ".staged-\(tool.rawValue)-\(UUID().uuidString)")
        switch tool {
        case .ytdlp:
            try await unzip(downloaded, into: item)
            let executable = item.appending(path: "yt-dlp_macos")
            guard FileManager.default.fileExists(atPath: executable.path) else { throw Failure.couldNotInstall(tool) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        case .quickJS:
            try FileManager.default.copyItem(at: downloaded, to: item)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
        }
        Self.removeQuarantine(under: item)
        return (tool, item, Record(version: release.tagName, sha256: try Self.hash(of: item)))
    }

    private func expectedHash(of tool: Tool, asset: Release.Asset, in release: Release) async throws -> String {
        switch tool {
        case .ytdlp:
            guard let sums = release.assets.first(where: { $0.name == "SHA2-256SUMS" }) else { throw Failure.missingAsset(tool) }
            let file = try await download(sums.browserDownloadURL)
            defer { try? FileManager.default.removeItem(at: file) }
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count == 2, parts[1] == asset.name { return parts[0].lowercased() }
            }
            throw Failure.missingAsset(tool)
        case .quickJS:
            guard let digest = asset.digest, digest.hasPrefix("sha256:") else { throw Failure.missingAsset(tool) }
            return String(digest.dropFirst("sha256:".count)).lowercased()
        }
    }

    private func unzip(_ zip: URL, into folder: URL) async throws {
        let result = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, folder.path], timeout: .seconds(120))
        guard result.status == 0, !result.timedOut else { throw Failure.couldNotInstall(.ytdlp) }
    }

    private func replace(_ installed: URL, with staged: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: installed.path) {
            _ = try manager.replaceItemAt(installed, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: installed)
        }
    }

    private static func removeQuarantine(under item: URL) {
        removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let walker = FileManager.default.enumerator(at: item, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    static func fileHash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hash(of item: URL) throws -> String {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder) else { throw Failure.notInstalled }
        guard isFolder.boolValue else { return try fileHash(item) }
        let base = item.standardizedFileURL.path
        var entries: [(String, String)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: item, includingPropertiesForKeys: keys) else { throw Failure.notInstalled }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            if values.isSymbolicLink == true {
                entries.append((relative, "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")))
            } else if values.isRegularFile == true {
                entries.append((relative, try fileHash(url)))
            }
        }
        var hasher = SHA256()
        for (path, hash) in entries.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data("\(path)\0\(hash)\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let source: GitHubSource
    private let lock = NSLock()
    private var wasRefused = false

    init(source: GitHubSource) {
        self.source = source
    }

    var refused: Bool { lock.withLock { wasRefused } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard source.allows(request.url) else {
            lock.withLock { wasRefused = true }
            task.cancel()
            return nil
        }
        return request
    }
}
