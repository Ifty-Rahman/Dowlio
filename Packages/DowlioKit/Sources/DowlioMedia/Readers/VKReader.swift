import Foundation

public struct VKReader: SiteReader {
    public let name = "VK"
    private let hosts: Set<String>
    private let embeds: URL

    public init(hosts: Set<String> = ["vk.com", "vk.ru", "vkvideo.ru"], embeds: URL = URL(string: "https://vk.com/video_ext.php")!) {
        self.hosts = hosts
        self.embeds = embeds
    }

    struct Clip {
        var owner: String
        var id: String
        var hash: String?
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && clip(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        clip(in: page).map { "\($0.owner)_\($0.id)" }
    }

    func clip(in page: URL) -> Clip? {
        if let owner = page.queryValue("oid"), let id = page.queryValue("id"), Int(owner) != nil, Int(id) != nil {
            return Clip(owner: owner, id: id, hash: page.queryValue("hash"))
        }
        let named = page.queryValue("z") ?? page.lastPathComponent
        guard let match = named.firstMatch(of: /^(?:video|clip)(-?\d+)_(\d+)/) else { return nil }
        return Clip(owner: String(match.1), id: String(match.2), hash: nil)
    }

    private static let playerParams = try! NSRegularExpression(pattern: #"playerParams\s*=\s*(\{.*?\})\s*;\s*\n"#, options: [.dotMatchesLineSeparators])

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let clip = clip(in: page.url), var address = URLComponents(url: embeds, resolvingAgainstBaseURL: false) else { return [] }
        address.queryItems = [URLQueryItem(name: "oid", value: clip.owner), URLQueryItem(name: "id", value: clip.id)] + (clip.hash.map { [URLQueryItem(name: "hash", value: $0)] } ?? [])
        guard let url = address.url else { return [] }
        let html = try await page.text(at: url)
        let ns = html as NSString
        guard let match = Self.playerParams.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              let params = try JSONSerialization.jsonObject(with: Data(ns.substring(with: match.range(at: 1)).utf8)) as? [String: Any],
              let video = params.objects("params").first else { throw SiteReaderError.unreadable }
        let label = PostLabel.of(text: video.text("md_title"), author: video.text("md_author"))
        if jsonNumber(video["is_live"]) == 1 { return [SiteVideo(label: label, restriction: .live)] }
        let versions = video.keys.sorted().compactMap { key -> Version? in
            guard key.hasPrefix("url"), let height = Int(key.dropFirst(3)), let file = URL(json: video[key]) else { return nil }
            return Version(source: .file(file), contentType: "video/mp4", height: height)
        }
        return [SiteVideo(
            label: label, thumbnail: URL(json: video["jpg"]), duration: jsonNumber(video["duration"]),
            versions: versions, streams: versions.isEmpty ? [video["hls"]].compactMap(URL.init(json:)) : []
        )]
    }
}
