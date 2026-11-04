import DowlioCore
import Foundation

enum YTDLPVersions {
    static let tallestH264 = 1080

    static func versions(of info: MediaInfo, page: URL) -> [Version] {
        let usable = info.formats.filter(isUsable)
        let audio = originalAudio(in: usable)
        guard let aac = best(audio.filter { MediaCodecs.isAAC($0.audioCodec ?? "") }) else { return [] }
        let videos = Dictionary(grouping: usable.filter(isH264Video), by: { $0.height ?? 0 })
            .compactMap { _, formats in best(formats) }
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        let rows = videos.compactMap { version(of: [$0, aac], container: .mp4, page: page, height: $0.height) }
        let sound = version(of: [aac], container: .m4a, page: page, height: nil)
        return rows + (sound.map { [$0] } ?? [])
    }

    private static func isUsable(_ format: MediaInfo.Format) -> Bool {
        guard format.url != nil, format.protocol == "https", !format.id.hasSuffix("-drc") else { return false }
        guard format.hasVideo || format.hasAudio else { return false }
        return (format.audioChannels ?? 2) <= 2
    }

    private static func isH264Video(_ format: MediaInfo.Format) -> Bool {
        guard let codec = format.videoCodec, !format.hasAudio, let height = format.height else { return false }
        return MediaCodecs.isH264(codec) && height <= tallestH264 && (format.dynamicRange ?? "SDR") == "SDR"
    }

    private static func originalAudio(in formats: [MediaInfo.Format]) -> [MediaInfo.Format] {
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo }
        let original = audio.filter(\.isOriginalAudio)
        if !original.isEmpty { return original }
        let preferred = audio.compactMap(\.languagePreference).max()
        return audio.filter { $0.languagePreference == preferred }
    }

    private static func best(_ formats: [MediaInfo.Format]) -> MediaInfo.Format? {
        formats.max { ($0.bitrate ?? 0, $0.size ?? 0) < ($1.bitrate ?? 0, $1.size ?? 0) }
    }

    private static func version(of formats: [MediaInfo.Format], container: MediaContainer, page: URL, height: Int?) -> Version? {
        let tracks = formats.compactMap { track(of: $0) }
        guard tracks.count == formats.count else { return nil }
        let expiry = formats.compactMap(\.expiry).min()
        let renewal = MediaRenewal(pageURL: page, formatIDs: formats.map(\.id))
        guard let source = try? MediaSource(tracks: tracks, container: container, expiry: expiry, renewal: renewal) else { return nil }
        let exact = formats.allSatisfy { $0.size != nil }
        let sizes = formats.compactMap { $0.size ?? $0.estimatedSize }
        return Version(
            source: .media(source),
            contentType: source.contentType,
            totalBytes: sizes.count == formats.count ? sizes.reduce(0, +) : nil,
            isEstimatedSize: !exact,
            height: height,
            codecs: MediaCodecs.names(formats.compactMap { $0.videoCodec } + formats.compactMap { $0.audioCodec }),
            userAgent: formats.lazy.compactMap { $0.headers["User-Agent"] }.first,
            requestSizeLimit: formats.compactMap(\.requestSizeLimit).min()
        )
    }

    private static func track(of format: MediaInfo.Format) -> MediaTrack? {
        guard let url = format.url else { return nil }
        let kind: MediaTrack.Kind = format.hasVideo ? (format.hasAudio ? .combined : .video) : .audio
        let bytes = format.size.flatMap { $0 > 0 ? 0...($0 - 1) : nil }
        let codecs = [format.videoCodec, format.audioCodec].compactMap { $0 }
        return MediaTrack(kind: kind, fragments: [MediaFragment(url: url, bytes: bytes)], codecs: codecs)
    }
}
