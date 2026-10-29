import Foundation

public struct StreamableReader: SiteReader {
    public let name = "Streamable"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["streamable.com"], api: URL = URL(string: "https://api.streamable.com/videos/")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        let id = parts.count == 2 && ["e", "o", "s"].contains(parts[0]) ? parts[1] : parts.count == 1 ? parts[0] : nil
        return id.flatMap { $0.count >= 3 && $0.allSatisfy { $0.isLetter || $0.isNumber } ? $0 : nil }
    }

    private static let embedAddress = try! NSRegularExpression(pattern: #"(?:https?:)?//(?:www\.)?streamable\.com/(?:e|o|s)/([a-zA-Z0-9]{3,})"#)

    public func embeds(in html: String) -> [URL] {
        EmbedAddresses.found(Self.embedAddress, in: html) { URL(string: "https://streamable.com/e/\($0)") }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url), let video = try await page.json(at: api.appending(path: id)) as? [String: Any] else { return [] }
        let files = video.object("files") ?? [:]
        let versions = files.keys.sorted().compactMap { key -> Version? in
            guard let file = files.object(key), let url = file.text("url").flatMap(Self.cleanedURL) else { return nil }
            let size = jsonNumber(file["size"]).flatMap { $0 > 0 ? Int64($0) : nil }
            return Version(source: .file(url), contentType: "video/mp4", totalBytes: size, height: shorterSide(file["width"], file["height"]))
        }
        let thumbnail = video.text("thumbnail_url").flatMap(Self.cleanedURL)
        return [SiteVideo(label: video.text("title"), thumbnail: thumbnail, versions: versions)]
    }

    private static func cleanedURL(_ text: String) -> URL? {
        var cleaned = text
        if let doubled = cleaned.firstMatch(of: /^https?:(https?:\/\/.*)$/) { cleaned = String(doubled.1) }
        if cleaned.hasPrefix("//") { cleaned = "https:" + cleaned }
        guard let url = URL(string: cleaned), url.host() != nil else { return nil }
        return url
    }
}
