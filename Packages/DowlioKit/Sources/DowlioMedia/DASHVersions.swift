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
        let usable = manifest.tracks.filter { !$0.fragments.isEmpty }
        let audio = usable.filter { $0.kind == .audio }
        let joinable = audio.filter { !isWebM($0) }
        let bestJoinable = joinable.max { rank($0) < rank($1) } ?? audio.max { rank($0) < rank($1) }
        let bestWebM = audio.filter(isWebM).max { rank($0) < rank($1) } ?? bestJoinable
        let allVideo = usable.filter { $0.kind == .video }
        let joinableHeights = Set(allVideo.filter { !isWebM($0) }.compactMap(\.height))
        let videos = allVideo
            .filter { !isWebM($0) || !joinableHeights.contains($0.height ?? -1) }
            .compactMap { video(of: $0, with: isWebM($0) ? bestWebM : bestJoinable, duration: manifest.duration) }
        let joinableLanguages = Set(joinable.map(\.language))
        let extraLanguages = audio.filter { isWebM($0) && !joinableLanguages.contains($0.language) }
        let sounds = (bestPerLanguage(joinable) + bestPerLanguage(extraLanguages)).compactMap { sound(of: $0, duration: manifest.duration) }
        guard !videos.isEmpty || !sounds.isEmpty else { return nil }
        return Candidate(label: label, thumbnail: thumbnail, duration: manifest.duration, versions: videos + sounds)
    }

    private static func isWebM(_ track: DASHTrack) -> Bool {
        let type = track.mimeType?.lowercased() ?? ""
        return type.contains("webm") || track.codecs.contains { MediaCodecs.needsWebM($0) || MediaCodecs.isVP($0) }
    }

    private static func container(video: DASHTrack?, audio: DASHTrack?) -> MediaContainer? {
        let parts = [video, audio].compactMap { $0 }
        return !parts.isEmpty && parts.allSatisfy(isWebM) ? .webm : nil
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
        guard let source = try? MediaSource(tracks: tracks, container: container(video: video, audio: audio)) else { return nil }
        let bandwidth = (video.bandwidth ?? 0) + (audio?.bandwidth ?? 0)
        return Version(
            source: .media(source), contentType: source.contentType, totalBytes: estimate(bandwidth, duration), isEstimatedSize: true,
            height: video.height, codecs: MediaCodecs.names(video.codecs + (audio?.codecs ?? []))
        )
    }

    private static func sound(of audio: DASHTrack, duration: Double?) -> Version? {
        guard let source = try? MediaSource(tracks: [MediaTrack(kind: .audio, dash: audio)], container: container(video: nil, audio: audio)) else {
            return nil
        }
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
        self.init(kind: kind, initialization: dash.initialization, fragments: dash.fragments, codecs: dash.codecs)
    }
}
