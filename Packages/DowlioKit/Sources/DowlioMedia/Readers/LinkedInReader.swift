import Foundation

public struct LinkedInReader: SiteReader {
    public let name = "LinkedIn"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["linkedin.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts)
    }

    public func post(in page: URL) -> String? {
        let path = page.path(percentEncoded: false)
        if let match = path.firstMatch(of: /(?:activity|ugcPost|share)[-:](\d{10,})/) { return String(match.1) }
        return nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        let cards = Self.cards(in: page.html ?? "")
        guard let id = post(in: page.url) else { return cards.flatMap(\.videos) }
        return cards.filter { $0.ids.contains(id) }.flatMap(\.videos)
    }

    private struct Card {
        var ids: Set<String>
        var videos: [SiteVideo]
    }

    private static func cards(in html: String) -> [Card] {
        let starts = html.matches(of: /data-activity-urn="urn:li:activity:(\d+)"/)
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].range.lowerBound : html.endIndex
            let card = String(html[start.range.lowerBound..<end])
            let text = commentary(in: card)
            let label = PostLabel.of(text: text, author: text == nil ? nil : actor(in: card))
            let videos = HTMLReader.tags(in: card, named: ["video"]).compactMap { video(of: $0.attributes, label: label) }
            guard !videos.isEmpty else { return nil }
            let attributed = card.prefix(600).firstMatch(of: /data-attributed-urn="urn:li:[a-zA-Z]+:(\d+)"/).map { String($0.1) }
            return Card(ids: Set([String(start.1)] + (attributed.map { [$0] } ?? [])), videos: videos)
        }
    }

    private static func actor(in card: String) -> String? {
        card.firstMatch(of: /data-tracking-control-name="[a-z_-]*actor-name"[^>]*>([^<]*)</).map { HTMLReader.decode(String($0.1)) }
    }

    private static func commentary(in card: String) -> String? {
        guard let match = card.firstMatch(of: /data-test-id="main-feed-activity-card__commentary"[^>]*>(.*?)<\/p>/.dotMatchesNewlines()) else { return nil }
        return HTMLReader.decode(String(match.1).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
    }

    private static func video(of attributes: [String: String], label: String?) -> SiteVideo? {
        guard let sources = attributes["data-sources"],
              let list = try? JSONSerialization.jsonObject(with: Data(sources.utf8)) as? [[String: Any]] else { return nil }
        var seen = Set<URL>()
        let versions = list.compactMap { source -> Version? in
            guard let url = URL(json: source["src"]), seen.insert(url).inserted,
                  MediaFile.kind(of: url, contentType: source.text("type")) == .video else { return nil }
            return Version(source: .file(url), contentType: source.text("type") ?? "video/mp4", height: MediaFile.height(in: url.path))
        }
        guard !versions.isEmpty else { return nil }
        return SiteVideo(label: label, thumbnail: attributes["data-poster-url"].flatMap(URL.init(string:)), versions: versions)
    }
}
