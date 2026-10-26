import DowlioCore
import Foundation

enum HLSVersions {
    static func isPlaylist(_ url: URL, contentType: String? = nil) -> Bool {
        url.pathExtension.lowercased() == "m3u8" || (contentType?.lowercased().contains("mpegurl") ?? false)
    }

    static func restriction(of media: MediaPlaylist) -> Candidate.Restriction? {
        if media.encryption == .protected { return .protected }
        return media.isComplete ? nil : .live
    }

    static func codecNames(_ codecs: [String]) -> String? {
        let named = codecs.compactMap { codec -> String? in
            let lowered = codec.lowercased()
            if lowered.hasPrefix("avc1") || lowered.hasPrefix("avc3") { return "H.264" }
            if lowered.hasPrefix("hvc1") || lowered.hasPrefix("hev1") { return "HEVC" }
            if lowered.hasPrefix("av01") { return "AV1" }
            if lowered.hasPrefix("vp09") || lowered.hasPrefix("vp9") { return "VP9" }
            if lowered.hasPrefix("mp4a") { return "AAC" }
            if lowered.hasPrefix("ac-3") { return "AC-3" }
            if lowered.hasPrefix("ec-3") { return "E-AC-3" }
            if lowered.hasPrefix("opus") { return "Opus" }
            return nil
        }
        var seen: [String] = []
        for name in named where !seen.contains(name) { seen.append(name) }
        return seen.isEmpty ? nil : seen.joined(separator: " + ")
    }

    static func hasAudio(_ codecs: [String]) -> Bool {
        codecs.isEmpty || codecs.contains(where: isAudioCodec)
    }

    private static func isAudioCodec(_ codec: String) -> Bool {
        ["mp4a", "ac-3", "ec-3", "opus"].contains { codec.lowercased().hasPrefix($0) }
    }

    static func version(of media: MediaPlaylist, variant: Variant?, audio listed: MediaPlaylist? = nil) -> Version? {
        guard isOffered(media) else { return nil }
        if let listed, restriction(of: listed) != nil { return nil }
        let audio = listed.flatMap { isOffered($0) ? $0 : nil }
        let codecs = variant?.codecs ?? []
        let source: DownloadSource
        if audio == nil, let file = media.singleFile {
            source = .file(file)
        } else {
            var tracks = [MediaTrack(kind: audio == nil && hasAudio(codecs) ? .combined : .video, playlist: media)]
            if let audio { tracks.append(MediaTrack(kind: .audio, playlist: audio)) }
            guard let built = try? MediaSource(tracks: tracks) else { return nil }
            source = .media(built)
        }
        let bandwidth = variant?.averageBandwidth ?? variant?.bandwidth
        return Version(
            source: source,
            contentType: "video/mp4",
            totalBytes: bandwidth.map { Int64(Double($0) * media.duration / 8) },
            isEstimatedSize: bandwidth != nil,
            height: variant?.height,
            codecs: codecNames(codecs)
        )
    }

    static func audioVersion(of media: MediaPlaylist, language: String?, codecs: [String]) -> Version? {
        guard isOffered(media), let built = try? MediaSource(tracks: [MediaTrack(kind: .audio, playlist: media)]) else { return nil }
        return Version(source: .media(built), contentType: built.contentType, codecs: codecNames(codecs.filter(isAudioCodec)), language: language)
    }

    private static func isOffered(_ media: MediaPlaylist) -> Bool {
        restriction(of: media) == nil && !media.fragments.isEmpty
    }
}

private extension MediaTrack {
    init(kind: Kind, playlist: MediaPlaylist) {
        self.init(kind: kind, initialization: playlist.initialization, fragments: playlist.fragments)
    }
}
