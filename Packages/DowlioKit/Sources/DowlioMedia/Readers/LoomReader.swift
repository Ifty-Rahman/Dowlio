import Foundation

public struct LoomReader: SiteReader {
    public let name = "Loom"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["loom.com"], api: URL = URL(string: "https://www.loom.com/api/campaigns/sessions/")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        guard let id = page.pathComponent(after: ["share", "embed"]) else { return nil }
        return id.count == 32 && id.allSatisfy(\.isHexDigit) ? id : nil
    }

    private static let embedAddress = try! NSRegularExpression(pattern: #"(?:https?:)?//(?:www\.)?loom\.com/(?:embed|share)/([0-9a-f]{32})"#)

    public func embeds(in html: String) -> [URL] {
        EmbedAddresses.found(Self.embedAddress, in: html) { URL(string: "https://www.loom.com/embed/\($0)") }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url) else { return [] }
        let body: [String: Any] = ["anonID": UUID().uuidString.lowercased(), "deviceID": NSNull(), "force_original": false, "password": NSNull()]
        guard let reply = try await page.json(posting: body, to: api.appending(path: "\(id)/transcoded-url")) as? [String: Any],
              let url = URL(json: reply["url"]) else { return [] }
        if DASHVersions.isStream(url) { return [SiteVideo(streams: [url])] }
        return [SiteVideo(versions: [Version(source: .file(url), contentType: "video/mp4")])]
    }
}
