import Foundation

public struct RedditReader: SiteReader {
    public let name = "Reddit"
    private let hosts: Set<String>
    private let videos: URL
    private let redgifs: URL

    public init(
        hosts: Set<String> = ["reddit.com", "redd.it"],
        videos: URL = URL(string: "https://v.redd.it")!,
        redgifs: URL = URL(string: "https://api.redgifs.com/v2/")!
    ) {
        self.hosts = hosts
        self.videos = videos
        self.redgifs = redgifs
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts)
    }

    public func post(in page: URL) -> String? {
        if page.host(percentEncoded: false)?.lowercased() == "redd.it" { return page.pathComponents.dropFirst().first }
        return page.pathComponent(after: ["comments", "s"])
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        let posts = Self.posts(in: page.html ?? "")
        guard let id = post(in: page.url) else { return await listed(posts, on: page) }
        let own = posts.filter { $0.id == "t3_\(id.lowercased())" }
        guard own.isEmpty, page.url.pathComponent(after: ["s"]) != nil else { return await listed(own, on: page) }
        return await listed(Array(posts.filter(\.isPageMain).prefix(1)), on: page)
    }

    private func listed(_ posts: [Post], on page: SitePage) async -> [SiteVideo] {
        var videos: [SiteVideo] = []
        for post in posts {
            if let video = await video(of: post, on: page) { videos.append(video) }
        }
        return videos
    }

    private struct Post {
        var id: String
        var title: String?
        var author: String?
        var link: URL?
        var player: URL?
        var poster: URL?
        var embedded: URL?
        var isPageMain = false
    }

    private static func posts(in html: String) -> [Post] {
        var posts: [Post] = []
        for tag in HTMLReader.tags(in: html, named: ["shreddit-post", "shreddit-player-2", "shreddit-player", "shreddit-embed"]) {
            let attributes = tag.attributes
            if tag.name == "shreddit-post" {
                guard let id = attributes["id"] else { continue }
                posts.append(Post(
                    id: id, title: attributes["post-title"], author: attributes["author"], link: attributes["content-href"].flatMap(URL.init(string:)),
                    isPageMain: attributes["view-context"] == "CommentsPage"
                ))
                continue
            }
            let index = attributes["post-id"].flatMap { id in posts.lastIndex { $0.id == id } } ?? posts.indices.last
            guard let index else { continue }
            if tag.name == "shreddit-embed" {
                posts[index].embedded = attributes["html"].flatMap { $0.firstMatch(of: /src="([^"]+)"/) }.flatMap { URL(string: String($0.1)) }
            } else {
                posts[index].player = posts[index].player ?? attributes["src"].flatMap(URL.init(string:))
                posts[index].poster = posts[index].poster ?? attributes["poster"].flatMap(URL.init(string:))
            }
        }
        return posts
    }

    private func video(of post: Post, on page: SitePage) async -> SiteVideo? {
        let streams: [URL]
        if let player = post.player {
            streams = [player]
        } else if let link = post.link, link.isOn(["v.redd.it"]), let id = link.pathComponents.dropFirst().first {
            streams = [videos.appending(path: id).appending(path: "HLSPlaylist.m3u8")]
        } else if let id = [post.link, post.embedded].compactMap(Self.redgifsID).first {
            guard var gif = try? await RedGifsReader.video(id: id, api: redgifs, page: page) else { return nil }
            gif.label = PostLabel.of(text: post.title, author: post.author) ?? gif.label
            gif.thumbnail = post.poster ?? gif.thumbnail
            return gif
        } else {
            return nil
        }
        return SiteVideo(label: PostLabel.of(text: post.title, author: post.author), thumbnail: post.poster, streams: streams)
    }

    private static func redgifsID(_ url: URL?) -> String? {
        guard let url, url.isOn(["redgifs.com"]) else { return nil }
        return RedGifsReader.id(in: url)
    }
}
