import DowlioCore
import Foundation
import os

public struct YTDLPRunner: Sendable {
    private static let logger = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "yt-dlp")

    public let installer: ToolInstaller
    let timeout: Duration
    let cookieFolder: URL
    let ffmpeg: URL?

    public init(
        installer: ToolInstaller, timeout: Duration = .seconds(30), cookieFolder: URL = YTDLPRunner.cookieFolder,
        ffmpeg: URL? = MediaRemuxer.bundledHelper
    ) {
        self.installer = installer
        self.timeout = timeout
        self.cookieFolder = cookieFolder
        self.ffmpeg = ffmpeg
    }

    static let downloadTimeout: Duration = .seconds(24 * 60 * 60)
    static let progressPrefix = "dowlio-progress"
    static let outputName = "media"

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

    public static let longestPlaylist = 1000

    public func info(for url: URL, cookies: [Cookie] = [], flatPlaylist: Bool = false) async throws -> MediaInfo {
        let tools = try await installer.verifiedTools()
        var arguments = ["--ignore-config", "--no-cache-dir"]
        arguments += flatPlaylist ? ["--flat-playlist", "--playlist-end", String(Self.longestPlaylist + 1)] : ["--no-playlist"]
        arguments += [
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

extension YTDLPRunner {
    public func renew(_ media: MediaSource, signIn: @Sendable (URL) async -> [Cookie] = { _ in [] }) async throws -> MediaSource {
        guard let renewal = media.renewal else { throw RenewalFailure.failed }
        guard await isInstalled else { throw RenewalFailure.toolsMissing }
        let info: MediaInfo
        do {
            info = try await infoRetryingWithSignIn(for: renewal.pageURL, signIn: signIn)
        } catch ToolInstaller.Failure.notInstalled {
            throw RenewalFailure.toolsMissing
        } catch let failure as YTDLPFailure {
            switch failure {
            case .needsSignIn, .private: throw RenewalFailure.needsSignIn
            case .network, .rateLimited: throw RenewalFailure.network
            default: throw RenewalFailure.failed
            }
        }
        let formats = renewal.formatIDs.compactMap { id in info.formats.first { $0.id == id } }
        let tracks = formats.compactMap { YTDLPVersions.track(of: $0) }
        guard tracks.count == renewal.formatIDs.count else { throw RenewalFailure.failed }
        return try MediaSource(
            tracks: tracks, keepsAudioOnly: media.keepsAudioOnly, container: media.container,
            expiry: formats.compactMap(\.expiry).min(), renewal: renewal
        )
    }

    private func infoRetryingWithSignIn(for page: URL, signIn: @Sendable (URL) async -> [Cookie]) async throws -> MediaInfo {
        do {
            return try await infoUpdatingIfBroken(for: page, cookies: [])
        } catch let failure as YTDLPFailure where failure == .needsSignIn || failure == .private {
            let cookies = await signIn(page)
            guard !cookies.isEmpty else { throw failure }
            return try await infoUpdatingIfBroken(for: page, cookies: cookies)
        }
    }

    func infoUpdatingIfBroken(for url: URL, cookies: [Cookie], flatPlaylist: Bool = false) async throws -> MediaInfo {
        do {
            return try await info(for: url, cookies: cookies, flatPlaylist: flatPlaylist)
        } catch YTDLPFailure.extractorBroken {
            guard await updateTools() else { throw YTDLPFailure.extractorBroken }
            return try await info(for: url, cookies: cookies, flatPlaylist: flatPlaylist)
        }
    }
}

extension YTDLPRunner {
    public func download(_ request: YTDLPDownload, signIn: @Sendable (URL) async -> [Cookie] = { _ in [] }) async throws -> URL {
        guard let renewal = request.media.renewal else { throw RenewalFailure.failed }
        guard await isInstalled else { throw RenewalFailure.toolsMissing }
        do {
            return try await downloadOnce(request, page: renewal.pageURL, formats: renewal.formatIDs, cookies: [])
        } catch DownloadError.needsSignIn {
            let cookies = await signIn(renewal.pageURL)
            guard !cookies.isEmpty else { throw DownloadError.needsSignIn }
            return try await downloadOnce(request, page: renewal.pageURL, formats: renewal.formatIDs, cookies: cookies)
        }
    }

    private func downloadOnce(_ request: YTDLPDownload, page: URL, formats: [String], cookies: [Cookie]) async throws -> URL {
        let tools = try await installer.verifiedTools()
        try FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true)
        let container = request.media.outputContainer
        var arguments = [
            "--ignore-config", "--no-cache-dir", "--no-playlist",
            "--js-runtimes", "quickjs:\(tools.quickJS.path)",
            "-f", formats.joined(separator: "+"),
            "--newline", "--no-colors", "--continue",
            "--progress-template",
            "download:\(Self.progressPrefix) %(info.format_id)s %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
            "-o", request.folder.appending(path: "\(Self.outputName).%(ext)s").path,
        ]
        if formats.count > 1 { arguments += ["--merge-output-format", container.rawValue] }
        if let ffmpeg { arguments += ["--ffmpeg-location", ffmpeg.path] }
        let jar = try cookies.isEmpty ? nil : CookieJar(cookies, in: cookieFolder)
        defer { jar?.remove() }
        if let jar { arguments += ["--cookies", jar.file.path] }
        arguments += ["--", page.absoluteString]
        let meter = ProgressMeter(formats: formats, report: request.progress)
        let result = try await ChildProcess.run(tools.ytdlp, arguments, timeout: Self.downloadTimeout) { line in meter.read(line) }
        if result.timedOut { throw DownloadError.network(NetworkFailure(code: .timedOut, message: "yt-dlp ran past its time limit")) }
        guard result.status == 0 else { throw YTDLPFailure.classify(result.errorText).downloadError }
        let finished = try FileManager.default.contentsOfDirectory(at: request.folder, includingPropertiesForKeys: nil)
            .filter { file in
                let parts = file.lastPathComponent.split(separator: ".")
                return parts.count == 2 && parts[0] == Self.outputName && !["part", "ytdl", "temp"].contains(String(parts[1]))
            }
        guard let file = finished.first(where: { $0.pathExtension == container.rawValue }) ?? finished.first else {
            throw DownloadError.mediaUnplayable
        }
        return file
    }
}

final class ProgressMeter: @unchecked Sendable {
    private struct Part {
        var received: Int64 = 0
        var total: Int64?
    }

    private let lock = NSLock()
    private let formats: [String]
    private let report: @Sendable (YTDLPProgress) -> Void
    private var parts: [String: Part] = [:]

    init(formats: [String], report: @escaping @Sendable (YTDLPProgress) -> Void) {
        self.formats = formats
        self.report = report
    }

    func read(_ line: String) {
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count == 7, fields[0] == YTDLPRunner.progressPrefix else { return }
        guard let received = Double(fields[2]).map({ Int64($0) }) else { return }
        let total = (Double(fields[3]) ?? Double(fields[4])).map { Int64($0) }
        let format = formats.contains(fields[1]) ? fields[1] : formats.joined(separator: "+")
        let progress: YTDLPProgress = lock.withLock {
            parts[format] = Part(received: received, total: total)
            let known = Array(parts.values)
            let sum = known.reduce(0) { $0 + $1.received }
            let totals = known.compactMap(\.total)
            let coversAll = parts[formats.joined(separator: "+")] != nil || formats.allSatisfy { parts[$0] != nil }
            let whole = coversAll && totals.count == known.count ? totals.reduce(0, +) : nil
            return YTDLPProgress(
                receivedBytes: sum, totalBytes: whole,
                bytesPerSecond: Double(fields[5]).map { Int64($0) } ?? 0, secondsLeft: Double(fields[6])
            )
        }
        report(progress)
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
