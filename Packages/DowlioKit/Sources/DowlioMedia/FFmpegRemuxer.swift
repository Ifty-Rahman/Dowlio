import DowlioCore
import Foundation
import ImageIO
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
        let chapters = try Self.writeChapters(request)
        defer { if let chapters { try? FileManager.default.removeItem(at: chapters) } }
        let result: ChildProcess.Result
        do {
            result = try await ChildProcess.run(executable, Self.arguments(for: request, chapters: chapters), timeout: timeout)
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

    static func arguments(for request: RemuxRequest, chapters: URL? = nil) -> [String] {
        let media = request.mediaSource
        let container = media.outputContainer
        let subtitles = media.isAudio ? [] : request.subtitles
        let cover = container == .webm ? nil : request.coverArt.flatMap { file in Self.imageSize(of: file).map { (file, $0) } }
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        var inputs = 0
        for track in request.tracks {
            arguments += ["-i", track.path]
            inputs += 1
        }
        let firstSubtitle = inputs
        for subtitle in subtitles {
            arguments += ["-i", subtitle.file.path]
            inputs += 1
        }
        let coverInput = cover.map { _ in inputs }
        if let (file, size) = cover {
            arguments += ["-video_size", "\(size.width)x\(size.height)", "-i", file.path]
            inputs += 1
        }
        let chaptersInput = chapters.map { _ in inputs }
        if let chapters {
            arguments += ["-f", "ffmetadata", "-i", chapters.path]
            inputs += 1
        }
        for index in request.tracks.indices {
            if !media.isAudio { arguments += ["-map", "\(index):v?"] }
            arguments += ["-map", "\(index):a?"]
        }
        for offset in subtitles.indices {
            arguments += ["-map", "\(firstSubtitle + offset):s"]
        }
        if let coverInput { arguments += ["-map", "\(coverInput):v"] }
        arguments += ["-c", "copy"]
        if !subtitles.isEmpty { arguments += ["-c:s", container == .webm ? "webvtt" : "mov_text"] }
        for (offset, subtitle) in subtitles.enumerated() {
            arguments += ["-metadata:s:s:\(offset)", "language=\(languageTag(subtitle.language))", "-metadata:s:s:\(offset)", "title=\(subtitle.name)"]
        }
        if coverInput != nil {
            let videoStreams = media.isAudio ? 0 : media.tracks.prefix(request.tracks.count).filter { $0.kind != .audio }.count
            arguments += ["-disposition:v:\(videoStreams)", "attached_pic"]
        }
        if let chaptersInput { arguments += ["-map_chapters", String(chaptersInput)] }
        if container != .webm { arguments += ["-movflags", "+faststart"] }
        arguments += ["-f", container.ffmpegFormat]
        arguments.append(request.output.path)
        return arguments
    }

    static func imageSize(of file: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func languageTag(_ code: String) -> String {
        Locale.Language(identifier: code).languageCode?.identifier(.alpha3) ?? "und"
    }

    private static func writeChapters(_ request: RemuxRequest) throws -> URL? {
        guard !request.chapters.isEmpty else { return nil }
        func escaped(_ text: String) -> String {
            var out = ""
            for character in text {
                if "=;#\\".contains(character) { out.append("\\") }
                out.append(character == "\n" ? " " : character)
            }
            return out
        }
        var text = ";FFMETADATA1\n"
        for chapter in request.chapters {
            text += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(chapter.start * 1000))\nEND=\(Int(chapter.end * 1000))\ntitle=\(escaped(chapter.title))\n"
        }
        let file = request.output.deletingLastPathComponent().appending(path: "chapters-\(UUID().uuidString).txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
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
