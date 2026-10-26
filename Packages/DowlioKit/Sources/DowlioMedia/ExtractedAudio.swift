import DowlioCore
import Foundation

extension Version {
    public static let extractionRangeSize: Int64 = 8 * 1024 * 1024
    private static let audioCodecs: Set<String> = ["AAC", "AC-3", "E-AC-3", "MP3"]
    private static let containersWithoutM4AAudio: Set<String> = ["webm", "mkv", "ogg", "ogv"]

    public var isAudio: Bool {
        if case .media(let media) = source { return media.isAudio }
        return MediaFile.kind(of: source.url, contentType: contentType) == .audio
    }

    public var isExtractedAudio: Bool {
        if case .media(let media) = source { return media.extractsAudio }
        return false
    }

    public static func extractedAudio(of video: Version, splitsIntoSegments: Bool = false, rangeSize: Int64 = extractionRangeSize) -> Version? {
        guard !(video.codecs ?? "").contains("Opus") else { return nil }
        let tracks: [MediaTrack]
        switch video.source {
        case .media(let media):
            guard !media.isAudio else { return nil }
            tracks = media.tracks.filter { $0.kind == .combined }
        case .file(let url):
            guard !video.isAudio, !containersWithoutM4AAudio.contains(url.pathExtension.lowercased()) else { return nil }
            tracks = [MediaTrack(kind: .combined, fragments: ranges(of: url, size: splitsIntoSegments ? video.totalBytes : nil, rangeSize: rangeSize))]
        }
        guard let source = try? MediaSource(tracks: tracks, keepsAudioOnly: true) else { return nil }
        let codecs = video.codecs?.components(separatedBy: " + ").filter(audioCodecs.contains)
        return Version(
            source: .media(source), contentType: source.contentType, totalBytes: video.totalBytes, isEstimatedSize: video.isEstimatedSize,
            codecs: codecs.flatMap { $0.isEmpty ? nil : $0.joined(separator: " + ") }
        )
    }

    private static func ranges(of url: URL, size: Int64?, rangeSize: Int64) -> [MediaFragment] {
        guard let size, size > rangeSize else { return [MediaFragment(url: url)] }
        return stride(from: Int64(0), to: size, by: Int(rangeSize)).map { start in
            MediaFragment(url: url, bytes: start...min(start + rangeSize, size) - 1)
        }
    }
}

extension Candidate {
    func withExtractedAudio(splittable: Set<URL>) -> Candidate {
        guard !versions.isEmpty, !versions.contains(where: \.isAudio),
              let smallest = versions.min(by: { ($0.totalBytes ?? .max, $0.height ?? .max) < ($1.totalBytes ?? .max, $1.height ?? .max) }),
              let audio = Version.extractedAudio(of: smallest, splitsIntoSegments: splittable.contains(smallest.source.url))
        else { return self }
        var candidate = self
        candidate.versions.append(audio)
        return candidate
    }
}
