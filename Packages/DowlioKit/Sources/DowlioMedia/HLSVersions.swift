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

    static func audioIsSeparate(for variant: Variant, in master: MasterPlaylist) -> Bool {
        guard let group = variant.audioGroup else { return false }
        return master.audio.contains { $0.groupID == group && $0.url != nil }
    }

    static func version(of media: MediaPlaylist, variant: Variant?, audioIsSeparate: Bool = false) -> Version? {
        guard restriction(of: media) == nil, !media.fragments.isEmpty else { return nil }
        let listed = variant?.codecs ?? []
        let codecs = audioIsSeparate ? listed.filter { !isAudioCodec($0) } : listed
        let source: DownloadSource
        if let file = media.singleFile {
            source = .file(file)
        } else {
            let track = MediaTrack(kind: !audioIsSeparate && hasAudio(codecs) ? .combined : .video, initialization: media.initialization, fragments: media.fragments)
            guard let built = try? MediaSource(tracks: [track]) else { return nil }
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
}
