import Foundation

public struct VidyardReader: SiteReader {
    public let name = "Vidyard"
    private let hosts: Set<String>
    private let player: URL

    public init(hosts: Set<String> = ["vidyard.com"], player: URL = URL(string: "https://play.vidyard.com")!) {
        self.hosts = hosts
        self.player = player
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        let candidate = parts.first == "watch" ? parts.dropFirst().first : parts.count == 1 ? parts.first : nil
        let id = candidate.map { $0.hasSuffix(".html") ? String($0.dropLast(5)) : $0 }
        return id.flatMap { Self.isID($0) ? $0 : nil }
    }

    private static func isID(_ text: String) -> Bool {
        (20...24).contains(text.count) && text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static let embedID = try! NSRegularExpression(pattern: #"(?:play\.vidyard\.com/|data-uuid=["']|vidyard\.com/watch/)([A-Za-z0-9]{20,24})\b"#)

    public func embeds(in html: String) -> [URL] {
        guard html.range(of: "vidyard", options: .caseInsensitive) != nil else { return [] }
        return EmbedAddresses.found(Self.embedID, in: html) { player.appending(path: $0) }
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url), let reply = try await page.json(at: player.appending(path: "player/\(id).json")) as? [String: Any] else { return [] }
        let chapters = (reply.object("payload") ?? reply).objects("chapters")
        return chapters.compactMap { chapter -> SiteVideo? in
            let sources = chapter.object("sources") ?? [:]
            let versions = sources.objects("mp4").compactMap { file -> Version? in
                guard let url = URL(json: file["url"]) else { return nil }
                return Version(source: .file(url), contentType: "video/mp4", height: file.text("profile").flatMap(MediaFile.height(in:)))
            }
            let streams = versions.isEmpty ? sources.objects("hls").filter { $0.text("profile") == "auto" }.compactMap { URL(json: $0["url"]) } : []
            guard !versions.isEmpty || !streams.isEmpty else { return nil }
            let thumbnails = chapter.object("thumbnailUrls") ?? [:]
            return SiteVideo(
                label: chapter.text("name"), thumbnail: URL(json: thumbnails["normal"] ?? thumbnails.values.first),
                duration: jsonNumber(chapter["seconds"]), versions: versions, streams: streams
            )
        }
    }
}
