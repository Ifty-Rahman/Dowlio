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

    static func version(of media: MediaPlaylist, variant: Variant?, audio listed: MediaPlaylist? = nil) -> Version? {
        guard isOffered(media) else { return nil }
        if let listed, restriction(of: listed) != nil { return nil }
        let audio = listed.flatMap { isOffered($0) ? $0 : nil }
        let codecs = variant?.codecs ?? []
        let source: DownloadSource
        if audio == nil, let file = media.singleFile {
            source = .file(file)
        } else {
            var tracks = [MediaTrack(kind: audio == nil && MediaCodecs.hasAudio(codecs) ? .combined : .video, playlist: media)]
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
            codecs: MediaCodecs.names(codecs)
        )
    }

    static func audioVersion(of media: MediaPlaylist, language: String?, codecs: [String]) -> Version? {
        guard isOffered(media), let built = try? MediaSource(tracks: [MediaTrack(kind: .audio, playlist: media)]) else { return nil }
        return Version(source: .media(built), contentType: built.contentType, codecs: MediaCodecs.names(codecs.filter(MediaCodecs.isAudio)), language: language)
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
