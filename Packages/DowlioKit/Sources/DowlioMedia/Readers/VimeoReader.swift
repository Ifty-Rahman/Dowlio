import Foundation

public struct VimeoReader: SiteReader {
    public let name = "Vimeo"
    private let hosts: Set<String>
    private let player: URL

    public init(hosts: Set<String> = ["vimeo.com"], player: URL = URL(string: "https://player.vimeo.com")!) {
        self.hosts = hosts
        self.player = player
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        func id(_ text: String?) -> String? { text.flatMap { $0.count >= 5 && $0.allSatisfy(\.isNumber) ? $0 : nil } }
        if parts.first == "video" { return id(parts.dropFirst().first) }
        if page.host(percentEncoded: false)?.lowercased().hasPrefix("player.") == true { return nil }
        if let first = id(parts.first), parts.count <= 2 { return first }
        if parts.count >= 3, ["video", "videos"].contains(parts[parts.count - 2]) { return id(parts.last) }
        if parts.count == 3, parts[0] == "channels" { return id(parts[2]) }
        return nil
    }

    public func embeds(in html: String) -> [URL] {
        let host = (player.host(percentEncoded: false) ?? "") + (player.port.map { ":\($0)" } ?? "")
        let pattern = try! NSRegularExpression(pattern: #"(?:https?:)?//"# + NSRegularExpression.escapedPattern(for: host) + #"/video/(\d{5,}(?:\?h=[0-9a-f]+)?)"#)
        return EmbedAddresses.found(pattern, in: html) { URL(string: "video/\($0)", relativeTo: player)?.absoluteURL }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url) else { return [] }
        var address = URLComponents(url: player.appending(path: "video/\(id)/config"), resolvingAgainstBaseURL: false)
        if let token = Self.privacyToken(in: page.url, after: id) { address?.queryItems = [URLQueryItem(name: "h", value: token)] }
        guard let url = address?.url, let config = try await page.json(at: url) as? [String: Any] else { return [] }
        let video = config.object("video") ?? [:]
        let label = video.text("title")
        let files = config.object("request")?.object("files") ?? [:]
        if video.text("privacy") == "password" || ((config["view"] as? Int) == 2 && files.isEmpty) {
            return [SiteVideo(label: label, restriction: .needsPassword)]
        }
        if video["live_event"] is [String: Any] { return [SiteVideo(label: label, restriction: .live)] }
        let versions = files.objects("progressive").compactMap { file -> Version? in
            guard let url = URL(json: file["url"]) else { return nil }
            return Version(source: .file(url), contentType: file.text("mime") ?? "video/mp4", height: shorterSide(file["width"], file["height"]))
        }
        let streams = ["hls", "dash"].compactMap { kind -> URL? in
            guard let delivery = files.object(kind), let cdns = delivery.object("cdns") else { return nil }
            let chosen = delivery.text("default_cdn").flatMap { cdns.object($0) } ?? cdns.values.lazy.compactMap { $0 as? [String: Any] }.first
            return URL(json: chosen?["url"])
        }
        let rules = page.framedBy.map { RequestRules(referrer: $0) }
        return [SiteVideo(
            label: label, thumbnail: URL(json: video["thumbnail_url"]), duration: jsonNumber(video["duration"]),
            versions: versions, streams: streams, rules: rules
        )]
    }

    private static func privacyToken(in page: URL, after id: String) -> String? {
        if let query = page.queryValue("h") { return query }
        let parts = page.pathComponents
        guard let index = parts.firstIndex(of: id), index + 1 < parts.count else { return nil }
        let next = parts[index + 1]
        return next.count >= 6 && next.allSatisfy(\.isHexDigit) ? next : nil
    }
}
