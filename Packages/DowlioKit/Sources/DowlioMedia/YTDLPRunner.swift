import DowlioCore
import Foundation
import os

public struct YTDLPRunner: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case timedOut
        case failed(String)
        case unreadable
    }

    private static let logger = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "yt-dlp")

    public let installer: ToolInstaller
    let timeout: Duration

    public init(installer: ToolInstaller, timeout: Duration = .seconds(30)) {
        self.installer = installer
        self.timeout = timeout
    }

    public var isInstalled: Bool {
        get async { await installer.isInstalled }
    }

    public func info(for url: URL) async throws -> MediaInfo {
        let tools = try await installer.verifiedTools()
        let arguments = [
            "--ignore-config", "--no-cache-dir", "--no-playlist",
            "--js-runtimes", "quickjs:\(tools.quickJS.path)",
            "--dump-single-json", "--", url.absoluteString,
        ]
        let result = try await ChildProcess.run(tools.ytdlp, arguments, timeout: timeout)
        if result.timedOut {
            Self.logger.error("yt-dlp ran past its timeout")
            throw Failure.timedOut
        }
        guard result.status == 0 else {
            let reason = result.errorText
            Self.logger.error("yt-dlp exited with \(result.status): \(reason, privacy: .private)")
            throw Failure.failed(reason)
        }
        guard let info = try? JSONDecoder().decode(MediaInfo.self, from: result.output) else { throw Failure.unreadable }
        return info
    }
}
