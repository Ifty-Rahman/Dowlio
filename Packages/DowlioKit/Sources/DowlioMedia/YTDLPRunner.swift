import DowlioCore
import Foundation
import os

public struct YTDLPRunner: Sendable {
    private static let logger = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "yt-dlp")

    public let installer: ToolInstaller
    let timeout: Duration
    let cookieFolder: URL

    public init(installer: ToolInstaller, timeout: Duration = .seconds(30), cookieFolder: URL = YTDLPRunner.cookieFolder) {
        self.installer = installer
        self.timeout = timeout
        self.cookieFolder = cookieFolder
    }

    public static var cookieFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Dowlio Cookies", directoryHint: .isDirectory)
    }

    public static func removeLeftoverCookies(in folder: URL = cookieFolder) {
        try? FileManager.default.removeItem(at: folder)
    }

    public var isInstalled: Bool {
        get async { await installer.isInstalled }
    }

    public func updateTools() async -> Bool {
        (try? await installer.update(unlessCheckedWithin: 60)) == true
    }

    public func info(for url: URL, cookies: [Cookie] = []) async throws -> MediaInfo {
        let tools = try await installer.verifiedTools()
        var arguments = [
            "--ignore-config", "--no-cache-dir", "--no-playlist",
            "--js-runtimes", "quickjs:\(tools.quickJS.path)",
            "--dump-single-json",
        ]
        let jar = try cookies.isEmpty ? nil : CookieJar(cookies, in: cookieFolder)
        defer { jar?.remove() }
        if let jar { arguments += ["--cookies", jar.file.path] }
        arguments += ["--", url.absoluteString]
        let result = try await ChildProcess.run(tools.ytdlp, arguments, timeout: timeout)
        if result.timedOut {
            Self.logger.error("yt-dlp ran past its timeout")
            throw YTDLPFailure.network
        }
        guard result.status == 0 else {
            let reason = result.errorText
            Self.logger.error("yt-dlp exited with \(result.status): \(reason, privacy: .private)")
            throw YTDLPFailure.classify(reason)
        }
        guard let info = try? JSONDecoder().decode(MediaInfo.self, from: result.output) else { throw YTDLPFailure.extractorBroken }
        if info.isLiveNow { throw YTDLPFailure.live }
        return info
    }
}

struct CookieJar {
    let folder: URL
    let file: URL

    init(_ cookies: [Cookie], in parent: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        folder = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        file = folder.appending(path: "cookies.txt")
        let expiry = Int(Date().timeIntervalSince1970) + 24 * 60 * 60
        let lines = cookies.compactMap { Self.line($0, expiring: expiry) }
        let text = (["# Netscape HTTP Cookie File"] + lines).joined(separator: "\n") + "\n"
        guard manager.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            try? manager.removeItem(at: folder)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func line(_ cookie: Cookie, expiring expiry: Int) -> String? {
        guard let domain = cookie.domain, !domain.isEmpty else { return nil }
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let shared = !cookie.hostOnly
        let written = shared ? "." + bare : bare
        let fields = [
            cookie.httpOnly ? "#HttpOnly_" + written : written,
            shared ? "TRUE" : "FALSE",
            cookie.path ?? "/",
            cookie.secure ? "TRUE" : "FALSE",
            String(expiry),
            cookie.name,
            cookie.value,
        ]
        return fields.map(clean).joined(separator: "\t")
    }

    private static func clean(_ field: String) -> String {
        String(field.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) })
    }
}
