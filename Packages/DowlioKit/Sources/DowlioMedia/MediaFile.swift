import Foundation

public enum MediaFile {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "ogg", "oga", "opus", "wav", "flac"]

    public static func kind(of url: URL, contentType: String? = nil) -> ScannedMedia.Kind? {
        if let type = contentType?.lowercased() {
            if type.hasPrefix("audio/") { return .audio }
            if type.hasPrefix("video/") { return .video }
        }
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    public static func height(in text: String) -> Int? {
        let lowered = text.lowercased()
        if let match = lowered.firstMatch(of: /(\d{3,4})x(\d{3,4})/), let width = Int(match.1), let height = Int(match.2) {
            return min(width, height)
        }
        if let match = lowered.firstMatch(of: /(?:^|[^\d])(\d{3,4})p(?![a-z])/), let height = Int(match.1) { return height }
        return nil
    }

    public static func codecs(in text: String) -> String? {
        let lowered = text.lowercased()
        let tokens = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ names: String...) -> Bool { names.contains { tokens.contains($0) } }
        if has("av1", "av01") { return "AV1" }
        if has("vp9", "vp09") { return "VP9" }
        if has("hevc", "h265", "hvc1", "hev1") || lowered.contains("h.265") { return "HEVC" }
        if has("h264", "avc", "avc1") || lowered.contains("h.264") { return "H.264" }
        return nil
    }
}
