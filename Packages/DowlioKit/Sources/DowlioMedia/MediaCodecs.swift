import Foundation

enum MediaCodecs {
    static func isAAC(_ codec: String) -> Bool {
        codec.lowercased().hasPrefix("mp4a")
    }

    static func needsWebM(_ codec: String) -> Bool {
        ["opus", "vorbis"].contains { codec.lowercased().hasPrefix($0) }
    }

    static func names(_ codecs: [String]) -> String? {
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

    static let videoNames: Set<String> = ["H.264", "HEVC", "AV1", "VP9"]

    static func videoCodec(in names: String?) -> String? {
        names?.components(separatedBy: " + ").first(where: videoNames.contains)
    }

    static func withAAC(_ video: String) -> String {
        "\(video) + AAC"
    }

    static let h264WithAAC = withAAC("H.264")

    static func hasAudio(_ codecs: [String]) -> Bool {
        codecs.isEmpty || codecs.contains(where: isAudio)
    }

    static func isAudio(_ codec: String) -> Bool {
        ["mp4a", "ac-3", "ec-3", "opus"].contains { codec.lowercased().hasPrefix($0) }
    }
}
