import Foundation

public struct InstagramReader: SiteReader {
    public let name = "Instagram"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["instagram.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts)
    }

    public func post(in page: URL) -> String? {
        let parts = page.pathComponents.filter { $0 != "/" }
        if parts.first == "stories" {
            guard parts.count >= 3, parts[1] != "highlights", !parts[2].isEmpty, parts[2].allSatisfy(\.isNumber) else { return nil }
            return parts[2]
        }
        guard let code = page.pathComponent(after: ["p", "reel", "reels", "tv"]) else { return nil }
        return code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } ? code : nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        MetaMedia.videos(on: page, post: post(in: page.url))
    }
}

enum MetaMedia {
    struct PostContext {
        var code: String?
        var label: String?
    }

    struct MediaItem {
        var key: String
        var code: String?
        var video: SiteVideo
    }

    static func videos(on page: SitePage, post code: String?) -> [SiteVideo] {
        let posts = posts(in: page.embeddedObjects, base: page.url)
        guard let code else { return posts.map(\.video) }
        return posts.filter { $0.code == code || $0.key == code || $0.key.hasPrefix(code + "_") }.map(\.video)
    }

    static func posts(in objects: [Any], base: URL) -> [MediaItem] {
        var found: [MediaItem] = []
        for object in objects { collect(object, post: nil, inCarousel: false, base: base, into: &found) }
        return found
    }

    private static func collect(_ value: Any, post inherited: PostContext?, inCarousel: Bool, base: URL, into found: inout [MediaItem]) {
        if let list = value as? [Any] {
            for child in list { collect(child, post: inherited, inCarousel: inCarousel, base: base, into: &found) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        let own = inCarousel ? nil : object.text("code").map { PostContext(code: $0, label: label(of: object)) }
        let post = own ?? inherited
        guard isMedia(object) else {
            for child in object.values { collect(child, post: post, inCarousel: false, base: base, into: &found) }
            return
        }
        if let children = object["carousel_media"] as? [Any] {
            for child in children { collect(child, post: post, inCarousel: true, base: base, into: &found) }
        }
        guard let video = video(in: object, label: post?.label ?? label(of: object), base: base) else { return }
        let key = (object["pk"] ?? object["id"]).map { "\($0)" } ?? video.versions.first?.source.url.absoluteString ?? ""
        if let index = found.firstIndex(where: { $0.key == key }) {
            if video.versions.count > found[index].video.versions.count { found[index].video = video }
        } else {
            found.append(MediaItem(key: key, code: post?.code, video: video))
        }
    }

    private static func isMedia(_ object: [String: Any]) -> Bool {
        object["video_versions"] is [Any] || object["video_dash_manifest"] is String || object["carousel_media"] is [Any]
    }

    private static func label(of object: [String: Any]) -> String? {
        let user = object.object("user")
        return PostLabel.of(text: object.object("caption")?.text("text"), author: user?.text("full_name") ?? user?.text("username"))
    }

    private static func video(in media: [String: Any], label: String?, base: URL) -> SiteVideo? {
        var versions: [Version] = []
        var seen = Set<URL>()
        let original = shorterSide(media["original_width"], media["original_height"])
        for entry in media.objects("video_versions") {
            guard let url = URL(json: entry["url"]), seen.insert(url).inserted else { continue }
            let height = shorterSide(entry["width"], entry["height"]) ?? MediaFile.height(inEncodingTagOf: url) ?? original
            versions.append(Version(source: .file(url), contentType: "video/mp4", height: height, codecs: MediaCodecs.h264WithAAC))
        }
        var duration = jsonNumber(media["video_duration"])
        if let xml = media["video_dash_manifest"] as? String,
           let manifest = try? MPDParser.parse(Data(xml.utf8), base: base),
           let dash = DASHVersions.candidate(of: manifest, label: label ?? "", thumbnail: nil), dash.restriction == nil {
            versions += dash.versions
            duration = duration ?? dash.duration
        }
        guard !versions.isEmpty else { return nil }
        let thumbnail = media.object("image_versions2")?.objects("candidates").first.flatMap { URL(json: $0["url"]) }
        return SiteVideo(label: label, thumbnail: thumbnail, duration: duration, versions: versions)
    }
}
