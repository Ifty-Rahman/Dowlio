import Foundation

public struct RumbleReader: SiteReader {
    public let name = "Rumble"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["rumble.com"], api: URL = URL(string: "https://rumble.com/embedJS/u3/")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && (Self.embedID(in: page) != nil || Self.isVideoPage(page))
    }

    public func post(in page: URL) -> String? {
        Self.embedID(in: page) ?? (Self.isVideoPage(page) ? page.lastPathComponent : nil)
    }

    static func embedID(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        guard parts.count >= 2, parts[0] == "embed", parts[1].hasPrefix("v"), parts[1].allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return parts[1]
    }

    private static func isVideoPage(_ page: URL) -> Bool {
        page.pathComponents.count == 2 && page.pathExtension == "html" && page.lastPathComponent.hasPrefix("v")
    }

    private static let embedAddress = try! NSRegularExpression(pattern: #"(?:https?:)?//(?:www\.)?rumble\.com/embed/(v[a-zA-Z0-9]+)"#)

    public func embeds(in html: String) -> [URL] {
        EmbedAddresses.found(Self.embedAddress, in: html) { URL(string: "https://rumble.com/embed/\($0)/") }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = try await embed(of: page) else { return [] }
        var address = URLComponents(url: api, resolvingAgainstBaseURL: false)
        address?.queryItems = [URLQueryItem(name: "request", value: "video"), URLQueryItem(name: "ver", value: "2"), URLQueryItem(name: "v", value: id)]
        guard let url = address?.url, let video = try await page.json(at: url) as? [String: Any] else { return [] }
        let label = video.text("title")
        if jsonNumber(video["live"]).map({ $0 != 0 }) == true { return [SiteVideo(label: label, restriction: .live)] }
        let sources = video.object("ua") ?? [:]
        let files = sources.object("mp4") ?? [:]
        let versions = files.keys.sorted().compactMap { key -> Version? in
            guard let file = files.object(key), let url = URL(json: file["url"]) else { return nil }
            let meta = file.object("meta") ?? [:]
            let size = jsonNumber(meta["size"]).flatMap { $0 > 0 ? Int64($0) : nil }
            return Version(source: .file(url), contentType: "video/mp4", totalBytes: size, height: shorterSide(meta["w"], meta["h"]) ?? Int(key))
        }
        let streams = versions.isEmpty ? (sources.object("hls") ?? [:]).values.compactMap { ($0 as? [String: Any])?["url"].flatMap { URL(json: $0) } } : []
        guard !versions.isEmpty || !streams.isEmpty else { return [] }
        return [SiteVideo(
            label: label, thumbnail: URL(json: video["i"]), duration: jsonNumber(video["duration"]), versions: versions,
            streams: Array(Set(streams)).sorted { $0.absoluteString < $1.absoluteString }
        )]
    }

    private static let pageEmbed = try! NSRegularExpression(pattern: #"rumble\.com/embed/(v[a-zA-Z0-9]+)"#)

    private func embed(of page: SitePage) async throws -> String? {
        if let id = Self.embedID(in: page.url) { return id }
        let html: String
        if let known = page.html { html = known } else { html = try await page.text(at: page.url) }
        return Self.embedAddress(in: html)
    }

    private static func embedAddress(in html: String) -> String? {
        let text = ScriptMedia.unescaped(html).replacingOccurrences(of: #"\/"#, with: "/")
        let ns = text as NSString
        return pageEmbed.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}
