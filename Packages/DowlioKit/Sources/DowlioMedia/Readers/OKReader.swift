import Foundation

public struct OKReader: SiteReader {
    public let name = "OK"
    private let hosts: Set<String>
    private let embeds: URL

    public init(hosts: Set<String> = ["ok.ru"], embeds: URL = URL(string: "https://ok.ru/videoembed/")!) {
        self.hosts = hosts
        self.embeds = embeds
    }

    private static let heights = ["mobile": 144, "lowest": 240, "low": 360, "sd": 480, "hd": 720, "full": 1080, "quad": 1440, "ultra": 2160]

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        guard let id = page.pathComponent(after: ["video", "videoembed", "live"]), id.count >= 6, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }

    private static let options = try! NSRegularExpression(pattern: #"data-options="([^"]*flashvars[^"]*)""#)

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url) else { return [] }
        var html = page.html ?? ""
        if !html.contains("flashvars") { html = try await page.text(at: embeds.appending(path: id)) }
        let ns = html as NSString
        guard let match = Self.options.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              let options = try JSONSerialization.jsonObject(with: Data(HTMLReader.decode(ns.substring(with: match.range(at: 1))).utf8)) as? [String: Any],
              let flashvars = options.object("flashvars") else { throw SiteReaderError.unreadable }
        let metadata: [String: Any]
        if let text = flashvars.text("metadata"), let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            metadata = parsed
        } else if let object = flashvars.object("metadata") {
            metadata = object
        } else {
            throw SiteReaderError.unreadable
        }
        let movie = metadata.object("movie") ?? [:]
        let versions = metadata.objects("videos").compactMap { video -> Version? in
            guard let url = URL(json: video["url"]) else { return nil }
            return Version(source: .file(url), contentType: "video/mp4", height: video.text("name").flatMap { Self.heights[$0] })
        }
        return [SiteVideo(
            label: movie.text("title"), thumbnail: URL(json: movie["poster"]), duration: jsonNumber(movie["duration"]),
            versions: versions, streams: versions.isEmpty ? [metadata["hlsManifestUrl"]].compactMap(URL.init(json:)) : []
        )]
    }
}
