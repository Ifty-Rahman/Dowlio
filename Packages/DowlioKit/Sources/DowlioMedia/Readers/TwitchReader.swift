import Foundation

public struct TwitchReader: SiteReader {
    public let name = "Twitch"
    private let hosts: Set<String>
    private let api: URL
    private let usher: URL

    static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let reserved: Set<String> = [
        "directory", "downloads", "jobs", "p", "search", "settings", "subscriptions", "turbo", "wallet", "friends", "inventory", "drops", "videos", "clips", "embed",
    ]

    public init(
        hosts: Set<String> = ["twitch.tv"], api: URL = URL(string: "https://gql.twitch.tv/gql")!, usher: URL = URL(string: "https://usher.ttvnw.net/")!
    ) {
        self.hosts = hosts
        self.api = api
        self.usher = usher
    }

    enum Target: Equatable {
        case clip(String)
        case broadcast(String)
        case channel(String)
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && Self.target(of: page) != nil
    }

    public func post(in page: URL) -> String? {
        switch Self.target(of: page) {
        case .clip(let slug): slug
        case .broadcast(let id): id
        case .channel, nil: nil
        }
    }

    static func target(of page: URL) -> Target? {
        let parts = Array(page.pathComponents.dropFirst())
        let onClipHost = page.host(percentEncoded: false)?.lowercased().hasPrefix("clips.") == true
        if onClipHost, let slug = parts.first, parts.count == 1 { return .clip(slug) }
        if let slug = page.pathComponent(after: ["clip"]) { return .clip(slug) }
        if let id = page.pathComponent(after: ["videos"]), parts.first == "videos", id.allSatisfy(\.isNumber) { return .broadcast(id) }
        if parts.count == 3, parts[1] == "videos", parts[2].allSatisfy(\.isNumber) { return .broadcast(parts[2]) }
        if parts.count == 1, !reserved.contains(parts[0].lowercased()), parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return .channel(parts[0].lowercased())
        }
        return nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        switch Self.target(of: page.url) {
        case .clip(let slug): try await clip(slug, page: page)
        case .broadcast(let id): try await broadcast(id, page: page)
        case .channel(let login): try await channel(login, page: page)
        case nil: []
        }
    }

    private func query(_ text: String, page: SitePage) async throws -> [String: Any] {
        let reply = try await page.json(posting: ["query": text], to: api, headers: ["Client-ID": Self.clientID]) as? [String: Any]
        return reply?.object("data") ?? [:]
    }

    private static func literal(_ text: String) -> String {
        let allowed = text.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return "\"\(allowed)\""
    }

    private static let tokenParameters = #"params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}"#

    private func clip(_ slug: String, page: SitePage) async throws -> [SiteVideo] {
        let data = try await query(
            """
            { clip(slug: \(Self.literal(slug))) { title durationSeconds thumbnailURL broadcaster { displayName } \
            playbackAccessToken(\(Self.tokenParameters)) { signature value } videoQualities { quality sourceURL } } }
            """,
            page: page
        )
        guard let clip = data.object("clip"), let token = clip.object("playbackAccessToken"),
              let signature = token.text("signature"), let value = token.text("value") else { return [] }
        let versions = clip.objects("videoQualities").compactMap { quality -> Version? in
            guard var parts = quality.text("sourceURL").flatMap({ URLComponents(string: $0) }) else { return nil }
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "sig", value: signature), URLQueryItem(name: "token", value: value)]
            guard let url = parts.url else { return nil }
            return Version(source: .file(url), contentType: "video/mp4", height: quality.text("quality").flatMap { Int($0) })
        }
        guard !versions.isEmpty else { return [] }
        let label = clip.text("title")
        return [SiteVideo(label: label, thumbnail: URL(json: clip["thumbnailURL"]), duration: jsonNumber(clip["durationSeconds"]), versions: versions)]
    }

    private func broadcast(_ id: String, page: SitePage) async throws -> [SiteVideo] {
        let data = try await query(
            """
            { videoPlaybackAccessToken(id: \(Self.literal(id)), \(Self.tokenParameters)) { signature value } \
            video(id: \(Self.literal(id))) { title lengthSeconds previewThumbnailURL } }
            """,
            page: page
        )
        guard let token = data.object("videoPlaybackAccessToken"), let signature = token.text("signature"), let value = token.text("value"),
              var parts = URLComponents(url: usher.appending(path: "vod/\(id).m3u8"), resolvingAgainstBaseURL: false) else { return [] }
        parts.queryItems = [
            URLQueryItem(name: "allow_source", value: "true"), URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "player", value: "twitchweb"), URLQueryItem(name: "sig", value: signature), URLQueryItem(name: "token", value: value),
        ]
        guard let playlist = parts.url else { return [] }
        let video = data.object("video")
        let thumbnail = video?.text("previewThumbnailURL").map { $0.replacingOccurrences(of: "{width}", with: "1280").replacingOccurrences(of: "{height}", with: "720") }
        return [SiteVideo(label: video?.text("title"), thumbnail: URL(json: thumbnail), duration: jsonNumber(video?["lengthSeconds"]), streams: [playlist])]
    }

    private func channel(_ login: String, page: SitePage) async throws -> [SiteVideo] {
        let data = try await query("{ user(login: \(Self.literal(login))) { displayName stream { id title } } }", page: page)
        guard let user = data.object("user"), let stream = user.object("stream") else { return [] }
        return [SiteVideo(label: stream.text("title") ?? user.text("displayName"), restriction: .live)]
    }
}
