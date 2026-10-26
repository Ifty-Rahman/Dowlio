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
}
