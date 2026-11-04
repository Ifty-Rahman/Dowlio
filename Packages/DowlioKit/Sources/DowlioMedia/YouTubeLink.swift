import Foundation

public struct YouTubeLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case video
    }

    public var kind: Kind
    public var isMusic: Bool

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hasVideo = query.contains { $0.name == "v" && !($0.value ?? "").isEmpty }
        let first = parts.first ?? ""
        let hasID = parts.count >= 2 && !parts[1].isEmpty
        switch bare {
        case "youtube.com", "m.youtube.com":
            guard (first == "watch" && parts.count == 1 && hasVideo) || (["shorts", "live", "embed"].contains(first) && hasID) else { return nil }
            isMusic = false
        case "music.youtube.com":
            guard first == "watch", parts.count == 1, hasVideo else { return nil }
            isMusic = true
        case "youtu.be":
            guard parts.count == 1, !first.isEmpty else { return nil }
            isMusic = false
        case "youtube-nocookie.com":
            guard first == "embed", hasID else { return nil }
            isMusic = false
        default:
            return nil
        }
        kind = .video
    }
}
