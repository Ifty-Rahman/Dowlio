import Foundation

public struct BlueskyReader: SiteReader {
    public let name = "Bluesky"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["bsky.app"], api: URL = URL(string: "https://public.api.bsky.app/xrpc")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        permalink(in: page)?.key
    }

    private func permalink(in page: URL) -> (author: String, key: String)? {
        guard let author = page.pathComponent(after: ["profile"]), let key = page.pathComponent(after: ["post"]) else { return nil }
        return (author, key)
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let (author, key) = permalink(in: page.url) else { return [] }
        var address = URLComponents(url: api.appending(path: "app.bsky.feed.getPostThread"), resolvingAgainstBaseURL: false)
        address?.queryItems = [
            URLQueryItem(name: "uri", value: "at://\(author)/app.bsky.feed.post/\(key)"),
            URLQueryItem(name: "depth", value: "0"),
            URLQueryItem(name: "parentHeight", value: "0"),
        ]
        guard let url = address?.url else { return [] }
        guard let thread = (try await page.json(at: url) as? [String: Any])?.object("thread"), let post = thread.object("post") else {
            throw SiteReaderError.unreadable
        }
        guard let video = Self.video(in: post.object("embed")), let playlist = URL(json: video["playlist"]) else { return [] }
        let poster = post.object("author")
        let label = PostLabel.of(text: post.object("record")?.text("text"), author: poster?.text("displayName") ?? poster?.text("handle"))
        return [SiteVideo(label: label, thumbnail: URL(json: video["thumbnail"]), streams: [playlist])]
    }

    private static func video(in embed: [String: Any]?) -> [String: Any]? {
        guard let embed else { return nil }
        if embed.text("playlist") != nil { return embed }
        return video(in: embed.object("media"))
    }
}
