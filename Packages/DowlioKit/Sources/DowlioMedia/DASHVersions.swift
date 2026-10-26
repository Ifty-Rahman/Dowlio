import DowlioCore
import Foundation

enum DASHVersions {
    static func isManifest(_ url: URL, contentType: String? = nil) -> Bool {
        url.pathExtension.lowercased() == "mpd" || (contentType?.lowercased().contains("dash+xml") ?? false)
    }

    static func isStream(_ url: URL, contentType: String? = nil) -> Bool {
        isManifest(url, contentType: contentType) || HLSVersions.isPlaylist(url, contentType: contentType)
    }

    static func candidate(of manifest: DASHManifest, label: String, thumbnail: URL?) -> Candidate? {
        if manifest.isProtected || manifest.isDynamic {
            return Candidate(label: label, thumbnail: thumbnail, duration: manifest.duration, versions: [], restriction: manifest.isProtected ? .protected : .live)
        }
        let usable = manifest.tracks.filter { !$0.fragments.isEmpty && canBeMuxed($0) }
        let audio = usable.filter { $0.kind == .audio }
        let best = audio.max { rank($0) < rank($1) }
        let videos = usable.filter { $0.kind == .video }.compactMap { video(of: $0, with: best, duration: manifest.duration) }
        let sounds = bestPerLanguage(audio).compactMap { sound(of: $0, duration: manifest.duration) }
        guard !videos.isEmpty || !sounds.isEmpty else { return nil }
        return Candidate(label: label, thumbnail: thumbnail, duration: manifest.duration, versions: videos + sounds)
    }

    private static func canBeMuxed(_ track: DASHTrack) -> Bool {
        let type = track.mimeType?.lowercased() ?? ""
        let codecs = track.codecs
        return !type.contains("webm") && !codecs.contains(where: MediaCodecs.needsWebM)
    }

    private static func rank(_ audio: DASHTrack) -> (Int, Int, Int) {
        (audio.isMain ? 1 : 0, audio.codecs.contains(where: MediaCodecs.isAAC) ? 1 : 0, audio.bandwidth ?? 0)
    }

    private static func bestPerLanguage(_ audio: [DASHTrack]) -> [DASHTrack] {
        var chosen: [DASHTrack] = []
        for candidate in audio {
            if let index = chosen.firstIndex(where: { $0.language == candidate.language }) {
                if rank(candidate) > rank(chosen[index]) { chosen[index] = candidate }
            } else {
                chosen.append(candidate)
            }
        }
        return chosen
    }

    private static func video(of video: DASHTrack, with audio: DASHTrack?, duration: Double?) -> Version? {
        var tracks = [MediaTrack(kind: audio == nil ? .combined : .video, dash: video)]
        if let audio { tracks.append(MediaTrack(kind: .audio, dash: audio)) }
        guard let source = try? MediaSource(tracks: tracks) else { return nil }
        let bandwidth = (video.bandwidth ?? 0) + (audio?.bandwidth ?? 0)
        return Version(
            source: .media(source), contentType: source.contentType, totalBytes: estimate(bandwidth, duration), isEstimatedSize: true,
            height: video.height, codecs: MediaCodecs.names(video.codecs + (audio?.codecs ?? []))
        )
    }

    private static func sound(of audio: DASHTrack, duration: Double?) -> Version? {
        guard let source = try? MediaSource(tracks: [MediaTrack(kind: .audio, dash: audio)]) else { return nil }
        return Version(
            source: .media(source), contentType: source.contentType, totalBytes: estimate(audio.bandwidth ?? 0, duration), isEstimatedSize: true,
            codecs: MediaCodecs.names(audio.codecs), language: audio.language
        )
    }

    private static func estimate(_ bandwidth: Int, _ duration: Double?) -> Int64? {
        guard bandwidth > 0, let duration else { return nil }
        return Int64(Double(bandwidth) * duration / 8)
    }
}

private extension MediaTrack {
    init(kind: Kind, dash: DASHTrack) {
        self.init(kind: kind, initialization: dash.initialization, fragments: dash.fragments)
    }
}
