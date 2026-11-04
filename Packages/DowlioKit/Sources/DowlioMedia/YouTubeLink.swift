import Foundation

public enum YouTubeLink: Equatable, Sendable {
    case video

    public init?(_ url: URL) {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path(percentEncoded: false)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hasVideo = query.contains { $0.name == "v" && !($0.value ?? "").isEmpty }
        switch bare {
        case "youtube.com", "m.youtube.com":
            guard path == "/watch", hasVideo else { return nil }
            self = .video
        default:
            return nil
        }
    }
}
