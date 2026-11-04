import DowlioCore
import Foundation

enum YTDLPVersions {
    static let tallestH264 = 1080

    static func versions(of info: MediaInfo, page: URL, decodesAV1: Bool) -> [Version] {
        let usable = info.formats.filter(isUsable)
        let audio = usable.filter { $0.hasAudio && !$0.hasVideo }
        let original = originalAudio(in: audio)
        let aac = best(original.filter(isAAC))
        let opus = best(original.filter(isOpus))
        let videos = usable.filter { $0.hasVideo && !$0.hasAudio && $0.height != nil }
        let rows = Dictionary(grouping: videos, by: { $0.height ?? 0 })
            .sorted { $0.key > $1.key }
            .compactMap { height, formats in row(at: height, from: formats, aac: aac, opus: opus, decodesAV1: decodesAV1, page: page) }
        let sound = aac.flatMap { version(of: [$0], container: .m4a, page: page, height: nil) }
        return rows + (sound.map { [$0] } ?? []) + dubs(in: audio, besides: original, page: page)
    }

    private static func row(
        at height: Int, from formats: [MediaInfo.Format], aac: MediaInfo.Format?, opus: MediaInfo.Format?, decodesAV1: Bool, page: URL
    ) -> Version? {
        let h264 = formats.filter { isH264($0) && isSDR($0) }
        if height <= tallestH264, let video = best(h264), let aac {
            return version(of: [video, aac], container: .mp4, page: page, height: height)
        }
        let av1 = formats.filter(isAV1)
        let vp9 = formats.filter(isVP9)
        let preferred = decodesAV1 ? [av1, vp9] : [vp9, av1]
        let choices = preferred.map { $0.filter(isSDR) } + preferred.map { $0.filter { !isSDR($0) } }
        for candidates in choices {
            guard let video = best(candidates) else { continue }
            let isWebM = isVP9(video)
            guard let audio = isWebM ? opus : aac else { continue }
            var row = version(of: [video, audio], container: isWebM ? .webm : .mp4, page: page, height: height)
            row?.isHDR = !isSDR(video)
            return row
        }
        return nil
    }

    private static func dubs(in audio: [MediaInfo.Format], besides original: [MediaInfo.Format], page: URL) -> [Version] {
        let originalLanguages = Set(original.compactMap(\.language))
        let others = Dictionary(grouping: audio.filter { isAAC($0) && $0.language != nil && !originalLanguages.contains($0.language ?? "") }) {
            $0.language ?? ""
        }
        return others.keys.sorted().compactMap { language in
            guard let dub = best(others[language] ?? []) else { return nil }
            var version = version(of: [dub], container: .m4a, page: page, height: nil)
            version?.language = Locale.current.localizedString(forLanguageCode: language) ?? language
            return version
        }
    }

    private static func isUsable(_ format: MediaInfo.Format) -> Bool {
        guard format.url != nil, format.protocol == "https", !format.id.hasSuffix("-drc") else { return false }
        guard format.hasVideo || format.hasAudio else { return false }
        return (format.audioChannels ?? 2) <= 2
    }

    private static func isH264(_ format: MediaInfo.Format) -> Bool { MediaCodecs.isH264(format.videoCodec ?? "") }
    private static func isAV1(_ format: MediaInfo.Format) -> Bool { (format.videoCodec ?? "").lowercased().hasPrefix("av01") }
    private static func isVP9(_ format: MediaInfo.Format) -> Bool { MediaCodecs.isVP(format.videoCodec ?? "") }
    private static func isAAC(_ format: MediaInfo.Format) -> Bool { MediaCodecs.isAAC(format.audioCodec ?? "") }
    private static func isOpus(_ format: MediaInfo.Format) -> Bool { (format.audioCodec ?? "").lowercased().hasPrefix("opus") }
    private static func isSDR(_ format: MediaInfo.Format) -> Bool { (format.dynamicRange ?? "SDR") == "SDR" }

    private static func originalAudio(in audio: [MediaInfo.Format]) -> [MediaInfo.Format] {
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
