import Foundation

public struct WistiaReader: SiteReader {
    public let name = "Wistia"
    private let hosts: Set<String>
    private let medias: URL

    public init(hosts: Set<String> = ["wistia.com", "wistia.net"], medias: URL = URL(string: "https://fast.wistia.com/embed/medias/")!) {
        self.hosts = hosts
        self.medias = medias
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        guard let id = page.pathComponent(after: ["medias", "iframe"]) else { return nil }
        let bare = id.hasSuffix(".json") ? String(id.dropLast(5)) : id
        return Self.isID(bare) ? bare : nil
    }

    private static func isID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isLowercase || $0.isNumber }
    }

    private static let embedID = try! NSRegularExpression(
        pattern: #"(?:wistia_async_|data-wistia-id=["']?|wistia\.(?:com|net)/(?:embed/)?(?:medias|iframe)/)([a-z0-9]{10})\b"#
    )

    public func embeds(in html: String) -> [URL] {
        EmbedAddresses.found(Self.embedID, in: html) { medias.appending(path: $0) }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url), let reply = try await page.json(at: medias.appending(path: "\(id).json")) as? [String: Any],
              let media = reply.object("media") else { return [] }
        let label = media.text("name")
        if media["protected"] as? Bool == true { return [SiteVideo(label: label, restriction: .protected)] }
        let assets = media.objects("assets")
        let versions = assets.compactMap { asset -> Version? in
            let type = asset.text("type") ?? ""
            guard type.hasSuffix("mp4_video") || type == "iphone_video", let url = URL(json: asset["url"]) else { return nil }
            let size = jsonNumber(asset["size"]).map(Int64.init)
            return Version(source: .file(url), contentType: "video/mp4", totalBytes: size, height: shorterSide(asset["width"], asset["height"]))
        }
        let still = assets.first { $0.text("type") == "still_image" }.flatMap { URL(json: $0["url"]) }
        return [SiteVideo(label: label, thumbnail: still, duration: jsonNumber(media["duration"]), versions: versions)]
    }
}
