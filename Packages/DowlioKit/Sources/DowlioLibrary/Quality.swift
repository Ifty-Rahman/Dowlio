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
        let (base, ext) = parts(label: label, version: version)
        let named = joined(base, ext)
        guard addsResolution, isTaken(named), let height = version.height else { return named }
        return joined("\(base) (\(height)p)", ext)
    }

    public static func fileName(
        label: String, version: Version, alongside siblings: [Version], addsResolution: Bool = true, isTaken: (String) -> Bool, besides named: Set<String>
    ) -> String {
        let (base, ext) = parts(label: label, version: version)
        let clashing = siblings.filter { $0 != version && MediaText.fileExtension(of: $0) == ext }
        let name: String
        if let height = version.height, !clashing.isEmpty {
            let sharesHeight = clashing.contains { $0.height == height }
            let tag = ["\(height)p", sharesHeight ? version.codecs : nil].compactMap { $0 }.joined(separator: " ")
            name = joined("\(base) (\(tag))", ext)
        } else {
            name = fileName(label: label, version: version, addsResolution: addsResolution, isTaken: isTaken)
        }
        guard named.contains(name) else { return name }
        let stem = (name as NSString).deletingPathExtension
        let numbered = (2...).lazy.map { joined("\(stem) \($0)", ext) }
        return numbered.first { !named.contains($0) && !isTaken($0) }!
    }

    private static func parts(label: String, version: Version) -> (base: String, ext: String) {
        let cleaned = label
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = MediaText.fileExtension(of: version)
        let named = cleaned.lowercased().hasSuffix(".\(ext.lowercased())") && !ext.isEmpty ? String(cleaned.dropLast(ext.count + 1)) : cleaned
        let base = named.isEmpty ? version.source.url.deletingPathExtension().lastPathComponent : String(named.prefix(120))
        return (base, ext)
    }

    private static func joined(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : "\(base).\(ext)"
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
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
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
