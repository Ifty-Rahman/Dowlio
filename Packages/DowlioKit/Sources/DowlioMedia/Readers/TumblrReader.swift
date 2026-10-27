import Foundation

public struct TumblrReader: SiteReader {
    public let name = "Tumblr"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["tumblr.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts)
    }

    public func post(in page: URL) -> String? {
        if let id = page.pathComponent(after: ["post"]) { return id }
        let parts = Array(page.pathComponents.dropFirst())
        let idIndex = parts.starts(with: ["blog", "view"]) ? 3 : 1
        return parts.count > idIndex && parts[idIndex].allSatisfy(\.isNumber) ? parts[idIndex] : nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        var seen = Set<String>()
        let posts = page.embeddedObjects.flatMap(Self.posts(in:)).filter { Self.id(of: $0).map { seen.insert($0).inserted } ?? true }
        guard let id = post(in: page.url) else { return posts.flatMap(Self.videos(in:)) }
        return posts.filter { Self.id(of: $0) == id || $0.objects("trail").contains { $0.object("post")?.text("id") == id } }.flatMap(Self.videos(in:))
    }

    private static func id(of post: [String: Any]) -> String? {
        post.text("idString") ?? post.text("id")
    }

    private static func posts(in value: Any) -> [[String: Any]] {
        if let list = value as? [Any] { return list.flatMap(posts(in:)) }
        guard let object = value as? [String: Any] else { return [] }
        if object["content"] is [Any], object.text("blogName") != nil { return [object] }
        return object.values.flatMap(posts(in:))
    }

    private static func videos(in post: [String: Any]) -> [SiteVideo] {
        let own = videos(in: post.objects("content"), blog: post.text("blogName"))
        let reblogged = post.objects("trail").flatMap { videos(in: $0.objects("content"), blog: $0.object("blog")?.text("name")) }
        return reblogged + own
    }

    private static func videos(in blocks: [[String: Any]], blog: String?) -> [SiteVideo] {
        let words = blocks.filter { $0.text("type") == "text" }.compactMap { $0.text("text") }
        let label = words.isEmpty ? nil : PostLabel.of(text: words.joined(separator: " "), author: blog)
        return blocks.filter { $0.text("type") == "video" && ($0.text("provider") ?? "tumblr") == "tumblr" }.compactMap { block in
            guard let media = block.object("media"), let url = URL(json: media["url"]),
                  MediaFile.kind(of: url, contentType: media.text("type")) == .video else { return nil }
            let version = Version(source: .file(url), contentType: media.text("type") ?? "video/mp4", height: shorterSide(media["width"], media["height"]))
            return SiteVideo(label: label, thumbnail: block.objects("poster").first.flatMap { URL(json: $0["url"]) }, versions: [version])
        }
    }
}
