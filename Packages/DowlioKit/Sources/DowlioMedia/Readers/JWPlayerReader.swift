import Foundation

public struct JWPlayerReader: SiteReader {
    public let name = "JW Player"
    private let api: URL
    private let player = WebPlayerReader(name: "JW Player", setupCalls: [WebPlayerReader.jwPlayerSetup])
    private static let mostHostedMedia = 5

    public init(api: URL = URL(string: "https://cdn.jwplayer.com")!) {
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool { false }
    public func recognisesPlayer(in html: String) -> Bool { player.recognisesPlayer(in: html) || !hostedMedia(in: html).isEmpty }
    public func post(in page: URL) -> String? { nil }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        var videos = try await player.read(page)
        let shown = Set(videos.flatMap { $0.versions.map(\.source.url) + $0.streams })
        for id in hostedMedia(in: page.html ?? "") {
            guard let reply = try? await page.json(at: api.appending(path: "v2/media/\(id)")) as? [String: Any] else { continue }
            videos += reply.objects("playlist").compactMap { item -> SiteVideo? in
                var setup = PlayerSetup.Found()
                setup.title = item.text("title") ?? reply.text("title")
                setup.poster = item.text("image")
                setup.duration = jsonNumber(item["duration"])
                setup.sources = item.objects("sources").compactMap { source in
                    source.text("file").map { PlayerSetup.Source(address: $0, height: jsonNumber(source["height"]).map(Int.init), type: source.text("type")) }
                }
                guard var video = setup.video(base: page.url) else { return nil }
                video.versions.removeAll { shown.contains($0.source.url) }
                video.streams.removeAll(where: shown.contains)
                return video.versions.isEmpty && video.streams.isEmpty ? nil : video
            }
        }
        return videos
    }

    private func hostedMedia(in html: String) -> [String] {
        let hosts = [api.host(percentEncoded: false) ?? "", "cdn.jwplayer.com", "content.jwplatform.com"].map(NSRegularExpression.escapedPattern(for:))
        let pattern = try! NSRegularExpression(pattern: "(?:" + hosts.joined(separator: "|") + #")(?::\d+)?/v2/(?:media|playlists)/([A-Za-z0-9]{8})"#)
        let ns = html as NSString
        var ids: [String] = []
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            if !ids.contains(id) { ids.append(id) }
        }
        return Array(ids.prefix(Self.mostHostedMedia))
    }
}
