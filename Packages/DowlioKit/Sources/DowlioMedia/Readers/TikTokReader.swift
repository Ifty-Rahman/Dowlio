import Foundation

public struct TikTokReader: SiteReader {
    public let name = "TikTok"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["tiktok.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts)
    }

    public func post(in page: URL) -> String? {
        switch permalink(in: page) {
        case .video(let id), .shortLink(let id): id
        case nil: nil
        }
    }

    private enum Permalink {
        case video(String)
        case shortLink(String)
    }

    private func permalink(in page: URL) -> Permalink? {
        if let id = page.pathComponent(after: ["video", "photo", "v"]) {
            return .video(id.replacingOccurrences(of: ".html", with: ""))
        }
        let host = page.host(percentEncoded: false)?.lowercased() ?? ""
        let isShortLink = host.hasPrefix("vm.") || host.hasPrefix("vt.") || page.pathComponents.dropFirst().first == "t"
        return isShortLink ? page.pathComponents.last.map(Permalink.shortLink) : nil
    }

    private struct Item {
        var id: String
        var object: [String: Any]
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        var seen = Set<String>()
        let items = page.embeddedObjects.flatMap(Self.items(in:)).filter { seen.insert($0.id).inserted }
        let chosen: [Item]
        switch permalink(in: page.url) {
        case nil: chosen = items
        case .video(let id): chosen = items.filter { $0.id == id }
        case .shortLink: chosen = Array(items.prefix(1))
        }
        return chosen.compactMap { Self.video(of: $0.object) }
    }

    private static func items(in value: Any) -> [Item] {
        if let list = value as? [Any] { return list.flatMap(items(in:)) }
        guard let object = value as? [String: Any] else { return [] }
        if let video = object.object("video"), video["playAddr"] != nil || video["bitrateInfo"] != nil, let id = object.text("id") {
            return [Item(id: id, object: object)]
        }
        return object.values.flatMap(items(in:))
    }

    private static func video(of item: [String: Any]) -> SiteVideo? {
        guard let video = item.object("video") else { return nil }
        var versions: [Version] = []
        var seen = Set<URL>()
        for rate in video.objects("bitrateInfo") {
            guard let address = rate.object("PlayAddr"), let url = address.list("UrlList").first.flatMap({ URL(json: $0) }),
                  seen.insert(url).inserted else { continue }
            versions.append(Version(
                source: .file(url), contentType: "video/mp4", totalBytes: jsonNumber(address["DataSize"]).map { Int64($0) },
                height: shorterSide(address["Width"], address["Height"]), codecs: codecs(rate.text("CodecType"))
            ))
        }
        if versions.isEmpty, let url = URL(json: video["playAddr"]) ?? URL(json: video["downloadAddr"]) {
            versions.append(Version(source: .file(url), contentType: "video/mp4", height: shorterSide(video["width"], video["height"]), codecs: codecs(video.text("codecType"))))
        }
        guard !versions.isEmpty else { return nil }
        let author = item.object("author")
        return SiteVideo(
            label: PostLabel.of(text: item.text("desc"), author: author?.text("nickname") ?? author?.text("uniqueId")),
            thumbnail: URL(json: video["cover"]) ?? URL(json: video["originCover"]),
            duration: jsonNumber(video["duration"]).flatMap { $0 > 0 ? $0 : nil },
            versions: versions
        )
    }

    private static func codecs(_ type: String?) -> String {
        let lowered = type?.lowercased() ?? ""
        return MediaCodecs.withAAC(lowered.contains("265") || lowered.contains("bytevc1") || lowered.contains("hevc") ? "HEVC" : "H.264")
    }
}
