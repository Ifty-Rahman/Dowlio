import Foundation

public struct TokenClipReader: SiteReader {
    public let name = "Short clips"
    private let api: URL?

    public init(api: URL? = nil) {
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        Self.id(in: page) != nil && (api != nil || Self.interfaceAddress(for: page) != nil)
    }

    public func post(in page: URL) -> String? {
        Self.id(in: page)
    }

    private static let embedAddress = try! NSRegularExpression(pattern: #"(?:https?:)?//([a-z0-9.-]+\.[a-z]{2,}/ifr/[a-zA-Z0-9]+)"#)

    public func embeds(in html: String) -> [URL] {
        EmbedAddresses.found(Self.embedAddress, in: html) { URL(string: "https://\($0.lowercased())") }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url) else { return [] }
        return try await Self.video(id: id, on: page.url, api: api, page: page).map { [$0] } ?? []
    }

    static func id(in url: URL) -> String? {
        url.pathComponent(after: ["watch", "ifr"])?.lowercased()
    }

    static func interfaceAddress(for page: URL) -> URL? {
        guard let host = page.host(percentEncoded: false)?.lowercased(), host.contains("."), host.contains(where: \.isLetter) else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return URL(string: "https://api.\(bare)/v2/")
    }

    static func video(id: String, on source: URL, api: URL?, page: SitePage) async throws -> SiteVideo? {
        guard let api = api ?? interfaceAddress(for: source),
              let token = (try await page.json(at: api.appending(path: "auth/temporary"), headers: [:]) as? [String: Any])?.text("token"),
              let gif = (try await page.json(at: api.appending(path: "gifs").appending(path: id), headers: ["Authorization": "Bearer \(token)"]) as? [String: Any])?.object("gif"),
              let urls = gif.object("urls")
        else { return nil }
        let height = shorterSide(gif["width"], gif["height"])
        let duration = jsonNumber(gif["duration"]).flatMap { $0 > 0 ? $0 : nil }
        var versions: [Version] = []
        if let hd = URL(json: urls["hd"]) {
            versions.append(Version(source: .file(hd), contentType: "video/mp4", height: height))
        }
        if let sd = URL(json: urls["sd"]) {
            versions.append(Version(source: .file(sd), contentType: "video/mp4"))
        }
        guard !versions.isEmpty else { return nil }
        let label = PostLabel.of(text: (gif["description"] as? String) ?? (gif["tags"] as? [String])?.joined(separator: " "), author: gif.text("userName"))
        return SiteVideo(label: label, thumbnail: URL(json: urls["poster"]) ?? URL(json: urls["thumbnail"]), duration: duration, versions: versions)
    }
}
