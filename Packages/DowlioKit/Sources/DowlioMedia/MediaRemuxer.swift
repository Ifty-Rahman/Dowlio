import DowlioCore
import Foundation

public struct MediaRemuxer: Sendable {
    public enum Error: Swift.Error, Equatable {
        case noHelper
    }

    enum Choice: Equatable {
        case avFoundation
        case ffmpeg
    }

    public let ffmpeg: URL?

    public init(ffmpeg: URL?) {
        self.ffmpeg = ffmpeg
    }

    public static let bundled = MediaRemuxer(ffmpeg: bundledHelper)

    public static var bundledHelper: URL? {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ffmpeg")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    public static func remux(_ request: RemuxRequest) async throws {
        try await bundled.remux(request)
    }

    public func remux(_ request: RemuxRequest) async throws {
        switch Self.choice(for: request) {
        case .avFoundation:
            do {
                try await AVRemuxer.remux(request.tracks, to: request.output)
            } catch where ffmpeg != nil && !Task.isCancelled && Self.hasUnknownCodecs(request.mediaSource) {
                try await ffmpegRemuxer().remux(request)
            }
        case .ffmpeg:
            try await ffmpegRemuxer().remux(request)
        }
    }

    private func ffmpegRemuxer() throws -> FFmpegRemuxer {
        guard let ffmpeg else { throw Error.noHelper }
        return FFmpegRemuxer(executable: ffmpeg)
    }

    static func choice(for request: RemuxRequest) -> Choice {
        let media = request.mediaSource
        if media.outputContainer == .webm || request.hasExtras { return .ffmpeg }
        let codecs = media.tracks.flatMap { $0.codecs ?? [] }
        if codecs.contains(where: { !MediaCodecs.joinsInAVFoundation($0) }) { return .ffmpeg }
        if request.tracks.contains(where: isMatroska) { return .ffmpeg }
        return .avFoundation
    }

    private static func hasUnknownCodecs(_ media: MediaSource) -> Bool {
        media.tracks.contains { ($0.codecs ?? []).isEmpty }
    }

    private static func isMatroska(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        return head == Data([0x1A, 0x45, 0xDF, 0xA3])
    }
}
