import Foundation

public struct BrightcoveReader: SiteReader {
    public let name = "Brightcove"
    private let hosts: Set<String>
    private let players: URL
    private let playback: URL

    public init(
        hosts: Set<String> = ["brightcove.net"], players: URL = URL(string: "https://players.brightcove.net")!,
        playback: URL = URL(string: "https://edge.api.brightcove.com/playback/v1/accounts/")!
    ) {
        self.hosts = hosts
        self.players = players
        self.playback = playback
    }

    struct Embed: Equatable {
        var account: String
        var player: String
        var video: String
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && embed(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        embed(in: page)?.video
    }

    func embed(in page: URL) -> Embed? {
        let parts = Array(page.pathComponents.dropFirst())
        guard parts.count >= 2, parts[0].allSatisfy(\.isNumber), let video = page.queryValue("videoId"), !video.isEmpty else { return nil }
        return Embed(account: parts[0], player: parts[1], video: video)
    }

    private static let videoTag = try! NSRegularExpression(pattern: #"<(?:video-js|video)\b[^>]*\bdata-account=["'](\d+)["'][^>]*>"#, options: [.caseInsensitive])
    private static let tagPlayer = try! NSRegularExpression(pattern: #"\bdata-player=["']([\w-]+)["']"#)
    private static let tagEmbed = try! NSRegularExpression(pattern: #"\bdata-embed=["']([\w-]+)["']"#)
    private static let tagVideo = try! NSRegularExpression(pattern: #"\bdata-video-id=["']([\w:-]+)["']"#)
    private static let policyKey = try! NSRegularExpression(pattern: #"policyKey["']?\s*:\s*["'](BCpk[\w-]+)["']"#)

    public func embeds(in html: String) -> [URL] {
        let host = (players.host(percentEncoded: false) ?? "") + (players.port.map { ":\($0)" } ?? "")
        let frame = try! NSRegularExpression(pattern: #"//"# + NSRegularExpression.escapedPattern(for: host) + #"/(\d+/[\w-]+_\w+/index\.html\?videoId=[\w:-]+)"#)
        var found = EmbedAddresses.found(frame, in: html) { URL(string: $0, relativeTo: players)?.absoluteURL }
        let ns = html as NSString
        for match in Self.videoTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            func attribute(_ pattern: NSRegularExpression) -> String? {
                let inner = tag as NSString
                return pattern.firstMatch(in: tag, range: NSRange(location: 0, length: inner.length)).map { inner.substring(with: $0.range(at: 1)) }
            }
            guard let video = attribute(Self.tagVideo) else { continue }
            let account = ns.substring(with: match.range(at: 1))
            let path = "\(account)/\(attribute(Self.tagPlayer) ?? "default")_\(attribute(Self.tagEmbed) ?? "default")/index.html?videoId=\(video)"
            if let url = URL(string: path, relativeTo: players)?.absoluteURL, !found.contains(url) { found.append(url) }
        }
        return found
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let embed = embed(in: page.url) else { return [] }
        let script = try await page.text(at: players.appending(path: "\(embed.account)/\(embed.player)/index.min.js"))
        let ns = script as NSString
        guard let match = Self.policyKey.firstMatch(in: script, range: NSRange(location: 0, length: ns.length)) else { throw SiteReaderError.unreadable }
        let key = ns.substring(with: match.range(at: 1))
        let address = playback.appending(path: "\(embed.account)/videos/\(embed.video)")
        guard let video = try await page.json(at: address, headers: ["Accept": "application/json;pk=\(key)"]) as? [String: Any] else { return [] }
        let label = video.text("name")
        let sources = video.objects("sources")
        let open = sources.filter { $0["key_systems"] == nil }
        if open.isEmpty, !sources.isEmpty { return [SiteVideo(label: label, restriction: .protected)] }
        var versions: [Version] = []
        var streams: [URL] = []
        for source in open {
            guard let url = URL(json: source["src"]), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            if versions.contains(where: { $0.source.url == url }) || streams.contains(url) { continue }
            let type = source.text("type")?.lowercased() ?? ""
            if type.contains("mpegurl") || type.contains("dash") {
                streams.append(url)
            } else if source.text("container")?.uppercased() == "MP4" || type == "video/mp4" {
                versions.append(Version(
                    source: .file(url), contentType: "video/mp4", totalBytes: jsonNumber(source["size"]).map(Int64.init),
                    height: shorterSide(source["width"], source["height"]), codecs: source.text("codec") == "H264" ? "H.264" : nil
                ))
            }
        }
        return [SiteVideo(
            label: label, thumbnail: URL(json: video["poster"]), duration: jsonNumber(video["duration"]).map { $0 / 1000 },
            versions: versions, streams: streams
        )]
    }
}
