import Foundation

public struct KickReader: SiteReader {
    public let name = "Kick"
    private let hosts: Set<String>
    private let api: URL

    private static let reserved: Set<String> = ["video", "categories", "browse", "following", "search", "dashboard", "settings", "terms-of-service", "privacy-policy", "emotes"]

    public init(hosts: Set<String> = ["kick.com"], api: URL = URL(string: "https://kick.com/api/")!) {
        self.hosts = hosts
        self.api = api
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
        case .clip(let id): id
        case .broadcast(let id): id
        case .channel, nil: nil
        }
    }

    static func target(of page: URL) -> Target? {
        let parts = Array(page.pathComponents.dropFirst())
        if let clip = page.queryValue("clip"), clip.hasPrefix("clip_") { return .clip(clip) }
        if parts.count == 3, parts[1] == "clips", parts[2].hasPrefix("clip_") { return .clip(parts[2]) }
        if parts.count == 2, parts[0] == "video", isUUID(parts[1]) { return .broadcast(parts[1].lowercased()) }
        if parts.count == 3, parts[1] == "videos", isUUID(parts[2]) { return .broadcast(parts[2].lowercased()) }
        if parts.count == 1, !reserved.contains(parts[0].lowercased()) { return .channel(parts[0].lowercased()) }
        return nil
    }

    private static func isUUID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        switch Self.target(of: page.url) {
        case .clip(let id): try await clip(id, page: page)
        case .broadcast(let id): try await broadcast(id, page: page)
        case .channel(let slug): try await channel(slug, page: page)
        case nil: []
        }
    }

    private func clip(_ id: String, page: SitePage) async throws -> [SiteVideo] {
        guard let clip = (try await page.json(at: api.appending(path: "v2/clips/\(id)")) as? [String: Any])?.object("clip"),
              let url = URL(json: clip["clip_url"]) ?? URL(json: clip["video_url"]) else { return [] }
        let thumbnail = URL(json: clip["thumbnail_url"])
        let duration = jsonNumber(clip["duration"])
        if DASHVersions.isStream(url) { return [SiteVideo(label: clip.text("title"), thumbnail: thumbnail, duration: duration, streams: [url])] }
        return [SiteVideo(label: clip.text("title"), thumbnail: thumbnail, duration: duration, versions: [Version(source: .file(url), contentType: "video/mp4")])]
    }

    private func broadcast(_ id: String, page: SitePage) async throws -> [SiteVideo] {
        guard let video = try await page.json(at: api.appending(path: "v1/video/\(id)")) as? [String: Any],
              let source = URL(json: video["source"]) else { return [] }
        let stream = video.object("livestream")
        let milliseconds = jsonNumber(stream?["duration"])
        return [SiteVideo(
            label: stream?.text("session_title"), thumbnail: URL(json: stream?.object("thumbnail")?["src"]),
            duration: milliseconds.map { $0 / 1000 }, streams: [source]
        )]
    }

    private func channel(_ slug: String, page: SitePage) async throws -> [SiteVideo] {
        guard let channel = try await page.json(at: api.appending(path: "v2/channels/\(slug)")) as? [String: Any],
              let live = channel.object("livestream") else { return [] }
        return [SiteVideo(label: live.text("session_title"), restriction: .live)]
    }
}
