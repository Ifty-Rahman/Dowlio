import Foundation

public struct RedGifsReader: SiteReader {
    public let name = "RedGifs"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["redgifs.com"], api: URL = URL(string: "https://api.redgifs.com/v2/")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        Self.id(in: page)
    }

    private static let embedAddress = try! NSRegularExpression(pattern: #"(?:https?:)?//(?:[a-z0-9-]+\.)?redgifs\.com/ifr/([a-zA-Z0-9]+)"#)

    public func embeds(in html: String) -> [URL] {
        EmbedAddresses.found(Self.embedAddress, in: html) { URL(string: "https://www.redgifs.com/ifr/\($0.lowercased())") }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url) else { return [] }
        return try await Self.video(id: id, api: api, page: page).map { [$0] } ?? []
    }

    static func id(in url: URL) -> String? {
        url.pathComponent(after: ["watch", "ifr"])?.lowercased()
    }

    static func video(id: String, api: URL, page: SitePage) async throws -> SiteVideo? {
        guard let token = (try await page.json(at: api.appending(path: "auth/temporary"), headers: [:]) as? [String: Any])?.text("token"),
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
