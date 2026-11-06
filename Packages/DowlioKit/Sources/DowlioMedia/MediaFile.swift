import Foundation

public enum MediaFile {
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "m2v", "3gp", "3g2", "ogv", "divx", "vob", "m2ts", "mts", "rmvb",
    ]
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "aac", "ogg", "oga", "opus", "wav", "flac", "aiff", "aif", "wma", "mka", "ape", "alac", "ac3", "dts", "wv",
    ]

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
        let sizes = Set(lowered.matches(of: /(\d{3,4})x(\d{3,4})/).compactMap { match in
            Int(match.1).flatMap { width in Int(match.2).map { min(width, $0) } }
        })
        if !sizes.isEmpty { return sizes.count == 1 ? sizes.first : nil }
        let named = Set(lowered.matches(of: /(?:^|[^\d])(\d{3,4})p(?![a-z])/).compactMap { Int($0.1) })
        return named.count == 1 ? named.first : nil
    }

    public static func height(inEncodingTagOf url: URL) -> Int? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard var encoded = query.first(where: { $0.name == "efg" })?.value else { return nil }
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["vencode_tag"] as? String,
              let match = tag.firstMatch(of: /\.(\d{3,4})\./) else { return nil }
        return Int(match.1)
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
