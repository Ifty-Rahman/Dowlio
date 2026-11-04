import DowlioCore
import DowlioMedia
import Foundation

public enum VideoQuality: Hashable, Sendable {
    case best
    case upTo(Int)

    public static let caps = [2160, 1440, 1080, 720, 480, 360]
}

public struct QualityPreference: Equatable, Sendable {
    public var quality: VideoQuality
    public var prefersH264: Bool

    public init(quality: VideoQuality = .best, prefersH264: Bool = true) {
        self.quality = quality
        self.prefersH264 = prefersH264
    }

    public func pick(from versions: [Version], showing: SentPageDraft.Showing) -> Version? {
        let shown = versions.filter { MediaText.isAudio($0) == (showing == .audio) }
        guard showing == .video else { return shown.max { ($0.totalBytes ?? 0) < ($1.totalBytes ?? 0) } ?? shown.first }
        let known = shown.compactMap { version in version.height.map { (version, $0) } }
        guard !known.isEmpty else { return shown.first }
        var eligible = known
        if case .upTo(let cap) = quality {
            let under = known.filter { $0.1 <= cap }
            let lowest = known.min { $0.1 < $1.1 }.map { [$0] } ?? []
            eligible = under.isEmpty ? lowest : under
        }
        if prefersH264 {
            let h264MP4 = eligible.filter { MediaText.isH264($0.0) && MediaText.isMP4($0.0) }
            let h264 = eligible.filter { MediaText.isH264($0.0) }
            eligible = !h264MP4.isEmpty ? h264MP4 : !h264.isEmpty ? h264 : eligible
        }
        return eligible.max { $0.1 < $1.1 }?.0
    }
}

public enum MediaNaming {
    public static func fileName(label: String, version: Version, addsResolution: Bool = true, isTaken: (String) -> Bool) -> String {
        let ext = MediaText.fileExtension(of: version)
        let cleaned = label
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? version.source.url.deletingPathExtension().lastPathComponent : String(cleaned.prefix(120))
        let named = ext.isEmpty ? base : "\(base).\(ext)"
        guard addsResolution, isTaken(named), let height = version.height else { return named }
        let withResolution = "\(base) (\(height)p)"
        return ext.isEmpty ? withResolution : "\(withResolution).\(ext)"
    }
}

public enum PlaylistNaming {
    public static func fileName(position: Int, of count: Int, title: String, fileExtension: String) -> String {
        let width = max(2, String(count).count)
        let number = String(repeating: "0", count: max(width - String(position).count, 0)) + String(position)
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(number) \(cleaned.isEmpty ? "Video" : String(cleaned.prefix(120))).\(fileExtension)"
    }

    public static func folderName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Playlist" : String(cleaned.prefix(120))
    }

    public static func media(for entry: PlaylistListing.Entry, showing: SentPageDraft.Showing, quality: VideoQuality, subtitles: [String]) -> MediaSource {
        let audioOnly = showing == .audio
        var tallest: Int?
        if case .upTo(let cap) = quality { tallest = cap }
        let choice = MediaRenewal.Choice(tallest: tallest, audioOnly: audioOnly, subtitleLanguages: audioOnly ? [] : subtitles)
        return try! MediaSource(
            tracks: [MediaTrack(kind: audioOnly ? .audio : .combined, fragments: [MediaFragment(url: entry.url)])],
            container: audioOnly ? .m4a : .mp4,
            renewal: MediaRenewal(pageURL: entry.url, formatIDs: [], choice: choice)
        )
    }
}
