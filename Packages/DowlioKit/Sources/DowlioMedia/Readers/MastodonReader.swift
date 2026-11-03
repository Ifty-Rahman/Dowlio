import Foundation

public struct MastodonReader: SiteReader {
    public let name = "Mastodon"

    public init() {}

    public func recognises(_ page: URL) -> Bool {
        post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        let id: String?
        if parts.count == 2, parts[0].hasPrefix("@"), parts[0].count > 1 {
            id = parts[1]
        } else if parts.count == 4, parts[0] == "users", parts[2] == "statuses" {
            id = parts[3]
        } else {
            id = nil
        }
        return id.flatMap { $0.count >= 15 && $0.allSatisfy(\.isNumber) ? $0 : nil }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url), var api = URLComponents(url: page.url, resolvingAgainstBaseURL: false) else { return [] }
        api.path = "/api/v1/statuses/\(id)"
        api.query = nil
        guard let url = api.url, let status = try await page.json(at: url) as? [String: Any] else { return [] }
        let shown = status.object("reblog") ?? status
        let account = shown.object("account") ?? [:]
        let label = PostLabel.of(text: Self.plain(shown.text("content")), author: account.text("display_name") ?? account.text("acct"))
        return shown.objects("media_attachments").compactMap { media -> SiteVideo? in
            guard ["video", "gifv"].contains(media.text("type") ?? ""), let url = URL(json: media["url"]) else { return nil }
            let original = media.object("meta")?.object("original") ?? [:]
            return SiteVideo(
                label: label ?? media.text("description"), thumbnail: URL(json: media["preview_url"]), duration: jsonNumber(original["duration"]),
                versions: [Version(source: .file(url), contentType: "video/mp4", height: shorterSide(original["width"], original["height"]))]
            )
        }
    }

    private static func plain(_ html: String?) -> String? {
        html.map { HTMLReader.decode($0.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)) }
    }
}
