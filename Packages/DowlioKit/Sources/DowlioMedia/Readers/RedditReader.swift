import Foundation

public struct RedditReader: SiteReader {
    public let name = "Reddit"
    private let hosts: Set<String>
    private let videos: URL
    private let clips: URL?

    public init(
        hosts: Set<String> = ["reddit.com", "redd.it"],
        videos: URL = URL(string: "https://v.redd.it")!,
        clips: URL? = nil
    ) {
        self.hosts = hosts
        self.videos = videos
        self.clips = clips
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
        guard let id = post(in: page.url) else { return await listed(posts, on: page) + playing(on: page, besides: posts) }
        let own = posts.filter { $0.id == "t3_\(id.lowercased())" }
        guard own.isEmpty, page.url.pathComponent(after: ["s"]) != nil else { return await listed(own, on: page) }
        return await listed(Array(posts.filter(\.isPageMain).prefix(1)), on: page)
    }

    private func playing(on page: SitePage, besides posts: [Post]) -> [SiteVideo] {
        var seen = Set(posts.compactMap { $0.link.flatMap(Self.hostedID) })
        return page.media.compactMap { url -> SiteVideo? in
            guard let id = Self.hostedID(url), seen.insert(id).inserted else { return nil }
            let packaged = page.media.filter { Self.hostedID($0) == id }.compactMap(Self.packagedFile)
            return SiteVideo(versions: packaged, streams: [videos.appending(path: id).appending(path: "HLSPlaylist.m3u8")])
        }
    }

    private static func packagedFile(_ url: URL) -> Version? {
        guard url.isOn(["packaged-media.redd.it"]), let height = url.lastPathComponent.firstMatch(of: /m2-res_(\d+)p\.mp4/).flatMap({ Int($0.1) }) else { return nil }
        return Version(source: .file(url), contentType: "video/mp4", height: height, codecs: MediaCodecs.h264WithAAC)
    }

    private static func hostedID(_ url: URL) -> String? {
        guard url.isOn(["v.redd.it", "packaged-media.redd.it"]) else { return nil }
        return url.pathComponents.dropFirst().first
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
        var packaged: [Version] = []
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
                if posts[index].packaged.isEmpty { posts[index].packaged = attributes["packaged-media-json"].map(packagedFiles) ?? [] }
            }
        }
        return posts
    }

    private func video(of post: Post, on page: SitePage) async -> SiteVideo? {
        let label = PostLabel.of(text: post.title, author: post.author)
        let streams: [URL]
        if let player = post.player, Self.isPlaylist(player) {
            streams = [player]
        } else if let link = post.link, link.isOn(["v.redd.it"]), let id = link.pathComponents.dropFirst().first {
            streams = [videos.appending(path: id).appending(path: "HLSPlaylist.m3u8")]
        } else if !post.packaged.isEmpty {
            return SiteVideo(label: label, thumbnail: post.poster, versions: post.packaged)
        } else if let player = post.player {
            streams = [player]
        } else if let (id, source) = [post.link, post.embedded].compactMap(Self.clipLink).first {
            guard var gif = try? await TokenClipReader.video(id: id, on: source, api: clips, page: page) else { return nil }
            gif.label = PostLabel.of(text: post.title, author: post.author) ?? gif.label
            gif.thumbnail = post.poster ?? gif.thumbnail
            return gif
        } else {
            return nil
        }
        return SiteVideo(label: label, thumbnail: post.poster, streams: streams)
    }

    private static func isPlaylist(_ url: URL) -> Bool {
        ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
    }

    private static func packagedFiles(_ json: String) -> [Version] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let mp4s = object["playbackMp4s"] as? [String: Any], let permutations = mp4s["permutations"] as? [[String: Any]]
        else { return [] }
        return permutations.compactMap { permutation in
            guard let source = permutation["source"] as? [String: Any], let url = (source["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let dimensions = source["dimensions"] as? [String: Any]
            return Version(
                source: .file(url), contentType: "video/mp4", height: shorterSide(dimensions?["width"], dimensions?["height"]), codecs: MediaCodecs.h264WithAAC
            )
        }
    }

    private static func clipLink(_ url: URL?) -> (String, URL)? {
        guard let url, !url.isOn(["reddit.com", "redd.it"]), let id = TokenClipReader.id(in: url) else { return nil }
        return (id, url)
    }
}
