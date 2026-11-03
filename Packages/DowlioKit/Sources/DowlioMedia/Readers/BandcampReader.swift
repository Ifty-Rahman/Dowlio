import Foundation

public struct BandcampReader: SiteReader {
    public let name = "Bandcamp"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["bandcamp.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && Self.slug(in: page, kinds: ["track", "album"]) != nil
    }

    public func post(in page: URL) -> String? {
        Self.slug(in: page, kinds: ["track"])
    }

    private static func slug(in page: URL, kinds: Set<String>) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        return parts.count == 2 && kinds.contains(parts[0]) ? parts[1] : nil
    }

    private static let tralbum = try! NSRegularExpression(pattern: #"data-tralbum="([^"]*)""#)

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard Self.slug(in: page.url, kinds: ["track", "album"]) != nil else { return [] }
        let html = try await page.loadedHTML()
        guard let attribute = AudioTrack.capture(Self.tralbum, in: html),
              let tralbum = try JSONSerialization.jsonObject(with: Data(HTMLReader.decode(attribute).utf8)) as? [String: Any] else { return [] }
        let artist = tralbum.text("artist")
        let art = jsonNumber(tralbum["art_id"]).map { Int64($0) }
        return tralbum.objects("trackinfo").compactMap { track -> SiteVideo? in
            let files = track.object("file") ?? [:]
            guard let stream = URL(json: files["mp3-128"]) ?? files.keys.sorted().first(where: { $0.hasPrefix("mp3-") }).flatMap({ URL(json: files[$0]) }) else { return nil }
            return SiteVideo(
                label: AudioTrack.label(artist: track.text("artist") ?? artist, title: track.text("title")),
                thumbnail: art.flatMap { URL(string: "https://f4.bcbits.com/img/a\($0)_10.jpg") }, duration: jsonNumber(track["duration"]),
                versions: [Version(source: .file(stream), contentType: "audio/mpeg", codecs: "MP3")]
            )
        }
    }
}
