import DowlioCore
import Foundation

enum YTDLPVersions {
    static let tallestH264 = 1080

    static func withExtras(_ versions: [Version], of info: MediaInfo, subtitles: SubtitlePreference) -> [Version] {
        let chapters = info.chapters.map { MediaExtras.Chapter(start: $0.start, end: $0.end, title: $0.title) }
        let video = MediaExtras(subtitles: SubtitleSelection.choose(info, for: subtitles), chapters: chapters, coverArt: info.coverArt)
        let audio = MediaExtras(coverArt: info.coverArt)
        return versions.map { version in
            guard case .media(let media) = version.source else { return version }
            var extras = media.isAudio ? audio : video
            if media.outputContainer == .webm { extras.coverArt = nil }
            var withExtras = version
            withExtras.source = .media(media.with(extras: extras))
            return withExtras
        }
    }

    static func pick(from versions: [Version], for choice: MediaRenewal.Choice) -> Version? {
        if choice.audioOnly { return versions.first { $0.isAudio && $0.language == nil } ?? versions.first(where: \.isAudio) }
        let videos = versions.filter { !$0.isAudio && $0.height != nil }
        guard let tallest = choice.tallest else { return videos.max { ($0.height ?? 0) < ($1.height ?? 0) } ?? versions.first { !$0.isAudio } }
        let fitting = videos.filter { ($0.height ?? 0) <= tallest }
        return fitting.max { ($0.height ?? 0) < ($1.height ?? 0) } ?? videos.min { ($0.height ?? 0) < ($1.height ?? 0) }
    }

    enum Path: Equatable {
        case engine
        case hls
        case dash
        case ytdlp
    }

    static func path(of format: MediaInfo.Format, playlists: [String: MediaPlaylist]) -> Path {
        switch format.protocol {
        case "https", "http": format.url == nil ? .ytdlp : .engine
        case "m3u8", "m3u8_native": playlists[format.id] == nil ? .ytdlp : .hls
        case "http_dash_segments": format.fragmentURLs.isEmpty ? .ytdlp : .dash
        default: .ytdlp
        }
    }

    static func needsPlaylist(_ format: MediaInfo.Format, among formats: [MediaInfo.Format]) -> Bool {
        guard format.protocol == "m3u8" || format.protocol == "m3u8_native", format.url != nil else { return false }
        let direct = formats.filter { ($0.protocol == "https" || $0.protocol == "http") && $0.url != nil }
        if format.hasVideo { return !direct.contains { $0.hasVideo && $0.height == format.height } }
        return !direct.contains { $0.hasAudio && !$0.hasVideo }
    }

    static func versions(of info: MediaInfo, page: URL, decodesAV1: Bool, playlists: [String: MediaPlaylist] = [:]) -> [Version] {
        let reach = Reach(playlists: playlists)
        let usable = info.formats.filter(isUsable)
        let audio = usable.filter { $0.hasAudio && !$0.hasVideo }
        let original = originalAudio(in: audio)
        let aac = reach.best(original.filter(isAAC))
        let opus = reach.best(original.filter(isOpus))
        let videos = usable.filter(\.hasVideo)
        var unsized = 0
        let rows = Dictionary(grouping: videos, by: { format -> Int in
            if let height = format.height { return height }
            unsized -= 1
            return unsized
        })
            .sorted { $0.key > $1.key }
            .compactMap { height, formats in
                row(at: height, from: formats, aac: aac, opus: opus, decodesAV1: decodesAV1, page: page, reach: reach)
            }
        let sound = aac.flatMap { reach.version(of: [$0], container: .m4a, page: page, height: nil) }
        return rows + (sound.map { [$0] } ?? []) + dubs(in: audio, besides: original, page: page, reach: reach)
    }

    private static func row(
        at height: Int, from formats: [MediaInfo.Format], aac: MediaInfo.Format?, opus: MediaInfo.Format?, decodesAV1: Bool, page: URL,
        reach: Reach
    ) -> Version? {
        let shown = height <= 0 ? nil : height
        let combined = formats.filter(\.hasAudio)
        let formats = formats.filter { !$0.hasAudio }
        let h264 = formats.filter { isH264($0) && isSDR($0) }
        if height <= tallestH264, let video = reach.best(h264), let aac {
            return reach.version(of: [video, aac], container: .mp4, page: page, height: shown)
        }
        let av1 = formats.filter(isAV1)
        let vp9 = formats.filter(isVP)
        let preferred = decodesAV1 ? [av1, vp9] : [vp9, av1]
        let choices = preferred.map { $0.filter(isSDR) } + preferred.map { $0.filter { !isSDR($0) } }
        for candidates in choices {
            guard let video = reach.best(candidates) else { continue }
            let isWebM = isVP(video)
            guard let audio = isWebM ? opus : aac else { continue }
            var chosen = reach.version(of: [video, audio], container: isWebM ? .webm : .mp4, page: page, height: shown)
            chosen?.isHDR = !isSDR(video)
            return chosen
        }
        guard let both = reach.best(combined.filter(isSDR)) ?? reach.best(combined) else { return nil }
        var chosen = reach.version(of: [both], container: isVP(both) ? .webm : .mp4, page: page, height: shown)
        chosen?.isHDR = !isSDR(both)
        return chosen
    }

    private static func dubs(in audio: [MediaInfo.Format], besides original: [MediaInfo.Format], page: URL, reach: Reach) -> [Version] {
        let originalLanguages = Set(original.compactMap { $0.language.map(baseLanguage) })
        var byName: [String: [MediaInfo.Format]] = [:]
        for format in audio where isAAC(format) {
            guard let code = format.language, !originalLanguages.contains(baseLanguage(code)) else { continue }
            byName[Locale.current.localizedString(forIdentifier: code) ?? code, default: []].append(format)
        }
        return byName.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard let format = reach.best(byName[name] ?? []) else { return nil }
            var dub = reach.version(of: [format], container: .m4a, page: page, height: nil)
            dub?.language = name
            return dub
        }
    }

    private static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
    }

    private static func isUsable(_ format: MediaInfo.Format) -> Bool {
        guard !format.id.hasSuffix("-drc"), format.protocol != "mhtml" else { return false }
        guard format.hasVideo || format.hasAudio else { return false }
        return (format.audioChannels ?? 2) <= 2
    }

    private static func isH264(_ format: MediaInfo.Format) -> Bool { MediaCodecs.isH264(format.videoCodec ?? "") }
    private static func isAV1(_ format: MediaInfo.Format) -> Bool { MediaCodecs.isAV1(format.videoCodec ?? "") }
    private static func isVP(_ format: MediaInfo.Format) -> Bool { MediaCodecs.isVP(format.videoCodec ?? "") }
    private static func isAAC(_ format: MediaInfo.Format) -> Bool { format.mayBeAAC }
    private static func isOpus(_ format: MediaInfo.Format) -> Bool { MediaCodecs.isOpus(format.audioCodec ?? "") }
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

    struct Reach {
        let playlists: [String: MediaPlaylist]

        func best(_ formats: [MediaInfo.Format]) -> MediaInfo.Format? {
            for path in [Path.engine, .hls, .dash, .ytdlp] {
                if let found = YTDLPVersions.best(formats.filter { YTDLPVersions.path(of: $0, playlists: playlists) == path }) { return found }
            }
            return nil
        }

        func version(of formats: [MediaInfo.Format], container: MediaContainer, page: URL, height: Int?) -> Version? {
            let byYTDLP = formats.contains { YTDLPVersions.path(of: $0, playlists: playlists) == .ytdlp }
            return YTDLPVersions.version(of: formats, container: container, page: page, height: height, playlists: byYTDLP ? nil : playlists)
        }
    }

    private static func version(
        of formats: [MediaInfo.Format], container: MediaContainer, page: URL, height: Int?, playlists: [String: MediaPlaylist]?
    ) -> Version? {
        let renewal = MediaRenewal(pageURL: page, formatIDs: formats.map(\.id))
        let expiry = formats.compactMap(\.expiry).min()
        let source: MediaSource
        if formats.count == 1, let only = formats.first, only.hasVideo, only.hasAudio, only.videoCodec == nil,
           path(of: only, playlists: playlists ?? [:]) == .engine, let url = only.url {
            return Version(
                source: .file(url), totalBytes: only.size ?? only.estimatedSize, isEstimatedSize: only.size == nil, height: height,
                referrer: only.headers["Referer"].flatMap(URL.init(string:)), origin: only.headers["Origin"], userAgent: only.headers["User-Agent"],
                requestSizeLimit: only.requestSizeLimit
            )
        }
        if let playlists {
            let tracks = formats.compactMap { track(of: $0, playlists: playlists) }
            guard tracks.count == formats.count,
                  let built = try? MediaSource(tracks: tracks, container: container, expiry: expiry, renewal: renewal) else { return nil }
            source = built
        } else {
            let kind: MediaTrack.Kind = formats.contains(where: \.hasVideo) ? .combined : .audio
            let placeholder = MediaTrack(kind: kind, fragments: [MediaFragment(url: page)], codecs: formats.flatMap { [$0.videoCodec, $0.audioCodec].compactMap { $0 } })
            guard let built = try? MediaSource(tracks: [placeholder], container: container, renewal: renewal, downloadsWithYTDLP: true) else { return nil }
            source = built
        }
        let exact = formats.allSatisfy { $0.size != nil }
        let sizes = formats.compactMap { $0.size ?? $0.estimatedSize }
        return Version(
            source: .media(source),
            contentType: source.contentType,
            totalBytes: sizes.count == formats.count ? sizes.reduce(0, +) : nil,
            isEstimatedSize: !exact,
            height: height,
            codecs: MediaCodecs.names(formats.compactMap { $0.videoCodec } + formats.compactMap { $0.audioCodec }),
            referrer: formats.lazy.compactMap { $0.headers["Referer"].flatMap(URL.init(string:)) }.first,
            origin: formats.lazy.compactMap { $0.headers["Origin"] }.first,
            userAgent: formats.lazy.compactMap { $0.headers["User-Agent"] }.first,
            requestSizeLimit: formats.compactMap(\.requestSizeLimit).min()
        )
    }

    static func track(of format: MediaInfo.Format, playlists: [String: MediaPlaylist] = [:]) -> MediaTrack? {
        let kind: MediaTrack.Kind = format.hasVideo ? (format.hasAudio ? .combined : .video) : .audio
        let codecs = [format.videoCodec, format.audioCodec].compactMap { $0 }
        switch path(of: format, playlists: playlists) {
        case .engine:
            guard let url = format.url else { return nil }
            let bytes = format.size.flatMap { $0 > 0 ? 0...($0 - 1) : nil }
            return MediaTrack(kind: kind, fragments: [MediaFragment(url: url, bytes: bytes)], codecs: codecs)
        case .hls:
            guard let playlist = playlists[format.id] else { return nil }
            return MediaTrack(kind: kind, initialization: playlist.initialization, fragments: playlist.fragments, codecs: codecs)
        case .dash:
            return MediaTrack(kind: kind, fragments: format.fragmentURLs.map { MediaFragment(url: $0) }, codecs: codecs)
        case .ytdlp:
            return nil
        }
    }
}
