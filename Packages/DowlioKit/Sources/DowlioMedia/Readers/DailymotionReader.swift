import Foundation

public struct DailymotionReader: SiteReader {
    public let name = "Dailymotion"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["dailymotion.com", "dai.ly"], api: URL = URL(string: "https://www.dailymotion.com/player/metadata/video/")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        if page.path.contains("player"), let id = page.queryValue("video") { return id }
        if let id = page.pathComponent(after: ["video"]) { return id.split(separator: "_").first.map(String.init) }
        guard page.host(percentEncoded: false)?.lowercased().hasSuffix("dai.ly") == true else { return nil }
        let id = page.lastPathComponent
        return id.count >= 5 && id.allSatisfy { $0.isLetter || $0.isNumber } ? id : nil
    }

    private static let embedAddress = try! NSRegularExpression(pattern: #"(?:https?:)?//(?:www\.)?dailymotion\.com/embed/video/([a-zA-Z0-9]{5,})"#)

    public func embeds(in html: String) -> [URL] {
        EmbedAddresses.found(Self.embedAddress, in: html) { URL(string: "https://www.dailymotion.com/embed/video/\($0)") }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url), let metadata = try await page.json(at: api.appending(path: id)) as? [String: Any] else { return [] }
        let label = metadata.text("title")
        if metadata["protected_delivery"] as? Bool == true { return [SiteVideo(label: label, restriction: .protected)] }
        if metadata.text("mode") == "live" { return [SiteVideo(label: label, restriction: .live)] }
        let posters = metadata.object("posters") ?? [:]
        let poster = posters.keys.compactMap { Int($0) }.max().flatMap { posters["\($0)"] }
        let streams = (metadata.object("qualities") ?? [:]).values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }.compactMap { quality -> URL? in
            guard (quality.text("type") ?? "").lowercased().contains("mpegurl") else { return nil }
            return URL(json: quality["url"])
        }
        return [SiteVideo(label: label, thumbnail: URL(json: poster), duration: jsonNumber(metadata["duration"]), streams: Array(Set(streams)).sorted { $0.absoluteString < $1.absoluteString })]
    }
}
