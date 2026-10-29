import Foundation

public struct KalturaReader: SiteReader {
    public let name = "Kaltura"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["kaltura.com"], api: URL = URL(string: "https://cdnapisec.kaltura.com")!) {
        self.hosts = hosts
        self.api = api
    }

    struct Entry: Equatable {
        var partner: String
        var id: String
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && entry(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        entry(in: page)?.id
    }

    func entry(in page: URL) -> Entry? {
        guard let partner = page.pathComponent(after: ["p"]), partner.allSatisfy(\.isNumber),
              let id = page.queryValue("entry_id") ?? page.pathComponent(after: ["entryId", "entry_id"]), Self.isEntryID(id) else { return nil }
        return Entry(partner: partner, id: id)
    }

    private static func isEntryID(_ text: String) -> Bool {
        text.firstMatch(of: /^[01]_[a-z0-9]{8}$/) != nil
    }

    private static let embeddedEntry = try! NSRegularExpression(pattern: #"/p/(\d+)/[^"'\s]*?entry_?[iI]d[=/]([01]_[a-z0-9]{8})"#)
    private static let partnerSetting = try! NSRegularExpression(pattern: #"(?:partner_?[iI]d|wid)["']?\s*[:=]\s*["']?_?(\d+)"#)
    private static let entrySetting = try! NSRegularExpression(pattern: #"entry_?[iI]d["']?\s*[:=]\s*["']([01]_[a-z0-9]{8})["']"#)

    public func embeds(in html: String) -> [URL] {
        let text = ScriptMedia.unescaped(html)
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var entries = Self.embeddedEntry.matches(in: text, range: whole).map {
            Entry(partner: ns.substring(with: $0.range(at: 1)), id: ns.substring(with: $0.range(at: 2)))
        }
        if let partner = Self.partnerSetting.firstMatch(in: text, range: whole).map({ ns.substring(with: $0.range(at: 1)) }) {
            entries += Self.entrySetting.matches(in: text, range: whole).map { Entry(partner: partner, id: ns.substring(with: $0.range(at: 1))) }
        }
        var found: [URL] = []
        for entry in entries {
            var address = URLComponents(url: api.appending(path: "p/\(entry.partner)/embedPlaykitJs"), resolvingAgainstBaseURL: false)
            address?.queryItems = [URLQueryItem(name: "entry_id", value: entry.id)]
            if let url = address?.url, !found.contains(url) { found.append(url) }
        }
        return found
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let entry = entry(in: page.url) else { return [] }
        let manifest = api.appending(path: "p/\(entry.partner)/sp/\(entry.partner)00/playManifest/entryId/\(entry.id)")
        return [SiteVideo(
            thumbnail: api.appending(path: "p/\(entry.partner)/thumbnail/entry_id/\(entry.id)/width/640"),
            versions: [Version(source: .file(manifest.appending(path: "format/url/protocol/https/a.mp4")), contentType: "video/mp4")],
            streams: [manifest.appending(path: "format/applehttp/protocol/https/a.m3u8")]
        )]
    }
}
