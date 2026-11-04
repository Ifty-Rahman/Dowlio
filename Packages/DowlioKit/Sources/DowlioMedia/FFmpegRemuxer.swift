import DowlioCore
import Foundation
import os

public struct FFmpegRemuxer: Sendable {
    public enum Error: Swift.Error, Equatable {
        case failed(String)
        case timedOut
    }

    private static let logger = Logger(subsystem: "io.github.ifty-rahman.Dowlio", category: "ffmpeg")

    public let executable: URL
    let timeout: Duration

    public init(executable: URL, timeout: Duration = .seconds(10 * 60)) {
        self.executable = executable
        self.timeout = timeout
    }

    public func remux(_ request: RemuxRequest) async throws {
        try? FileManager.default.removeItem(at: request.output)
        let result: ChildProcess.Result
        do {
            result = try await ChildProcess.run(executable, Self.arguments(for: request), timeout: timeout)
        } catch {
            try? FileManager.default.removeItem(at: request.output)
            throw error
        }
        guard !result.timedOut, result.status == 0 else {
            try? FileManager.default.removeItem(at: request.output)
            if result.timedOut { throw Error.timedOut }
            let reason = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logger.error("ffmpeg exited with \(result.status): \(reason, privacy: .private)")
            throw Error.failed(reason)
        }
    }

    static func arguments(for request: RemuxRequest) -> [String] {
        let media = request.mediaSource
        let container = media.outputContainer
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        for track in request.tracks {
            arguments += ["-i", track.path]
        }
        for index in request.tracks.indices {
            if !media.isAudio { arguments += ["-map", "\(index):v?"] }
            arguments += ["-map", "\(index):a?"]
        }
        arguments += ["-c", "copy"]
        if container != .webm { arguments += ["-movflags", "+faststart"] }
        arguments += ["-f", container.ffmpegFormat]
        arguments.append(request.output.path)
        return arguments
    }
}

private extension MediaContainer {
    var ffmpegFormat: String {
        switch self {
        case .mp4: "mp4"
        case .m4a: "ipod"
        case .webm: "webm"
        }
    }
}
