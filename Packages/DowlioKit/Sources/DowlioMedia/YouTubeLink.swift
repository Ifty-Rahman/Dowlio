import Foundation

public struct YouTubeLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case video
        case playlist
        case videoInPlaylist(list: String)
        case channel
    }

    public var kind: Kind
    public var isMusic: Bool

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        let isWatch = parts == ["watch"] && value("v") != nil
        let first = parts.first ?? ""
        let hasID = parts.count == 2 && !parts[1].isEmpty && parts[1] != "videoseries"
        isMusic = bare == "music.youtube.com"
        switch bare {
        case "youtube.com", "m.youtube.com", "music.youtube.com":
            if parts == ["playlist"], value("list") != nil {
                kind = .playlist
            } else if isWatch, let list = value("list"), Self.isRealPlaylist(list) {
                kind = .videoInPlaylist(list: list)
            } else if isWatch {
                kind = .video
            } else if !isMusic, ["shorts", "live", "embed"].contains(first), hasID {
                kind = .video
            } else if isMusic, first == "browse", hasID {
                kind = .playlist
            } else if !isMusic, first.hasPrefix("@") || (["channel", "c", "user"].contains(first) && parts.count >= 2) {
                kind = .channel
            } else {
                return nil
            }
        case "youtu.be":
            guard parts.count == 1 else { return nil }
            kind = value("list").flatMap { Self.isRealPlaylist($0) ? .videoInPlaylist(list: $0) : nil } ?? .video
        case "youtube-nocookie.com":
            guard first == "embed", hasID else { return nil }
            kind = .video
        default:
            return nil
        }
    }

    static func isRealPlaylist(_ list: String) -> Bool {
        !["WL", "LL", "LM"].contains(list) && !list.hasPrefix("RD")
    }

    public static func playlistURL(list: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/playlist")!
        components.queryItems = [URLQueryItem(name: "list", value: list)]
        return components.url!
    }
}
