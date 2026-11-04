import Foundation

public struct YouTubeLink: Equatable, Sendable {
    public var isMusic: Bool

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isWatch = parts == ["watch"] && query.contains { $0.name == "v" && !($0.value ?? "").isEmpty }
        let first = parts.first ?? ""
        let hasID = parts.count == 2 && !parts[1].isEmpty && parts[1] != "videoseries"
        isMusic = bare == "music.youtube.com"
        switch bare {
        case "youtube.com", "m.youtube.com":
            guard isWatch || (["shorts", "live", "embed"].contains(first) && hasID) else { return nil }
        case "music.youtube.com":
            guard isWatch else { return nil }
        case "youtu.be":
            guard parts.count == 1 else { return nil }
        case "youtube-nocookie.com":
            guard first == "embed", hasID else { return nil }
        default:
            return nil
        }
    }
}
