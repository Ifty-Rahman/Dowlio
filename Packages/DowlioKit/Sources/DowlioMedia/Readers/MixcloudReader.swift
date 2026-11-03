import Foundation

public struct MixcloudReader: SiteReader {
    public let name = "Mixcloud"
    private let hosts: Set<String>

    private static let reserved: Set<String> = ["discover", "upload", "select", "settings", "dashboard", "categories", "live", "tag", "popular", "search"]
    private static let profileSections: Set<String> = ["playlists", "favorites", "listens", "followers", "following", "uploads", "stream", "history", "shows", "reposts"]

    public init(hosts: Set<String> = ["mixcloud.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        guard parts.count == 2, !Self.reserved.contains(parts[0].lowercased()), !Self.profileSections.contains(parts[1].lowercased()) else { return nil }
        return parts.joined(separator: "/")
    }

    private static let relayData = try! NSRegularExpression(pattern: #"<script[^>]*id="relay-data"[^>]*>(.*?)</script>"#, options: .dotMatchesLineSeparators)

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        let html = try await page.loadedHTML()
        guard let raw = AudioTrack.capture(Self.relayData, in: html),
              let data = try? JSONSerialization.jsonObject(with: Data(HTMLReader.decode(raw).utf8)),
              let show = AudioTrack.first("streamInfo", in: data), let stream = show.object("streamInfo") else { throw SiteReaderError.unreadable }
        let hls = URL(json: stream["hlsUrl"])
        let file = URL(json: stream["url"])
        guard hls != nil || file != nil else { throw SiteReaderError.unreadable }
        let owner = show.object("owner")?.text("displayName") ?? show.object("owner")?.text("username")
        let thumbnail = show.object("picture")?.text("urlRoot").flatMap { URL(string: "https://thumbnailer.mixcloud.com/unsafe/600x600/\($0)") }
        var versions: [Version] = []
        if let file {
            let isMP3 = file.pathExtension.lowercased() == "mp3"
            versions.append(Version(source: .file(file), contentType: isMP3 ? "audio/mpeg" : "audio/mp4", codecs: isMP3 ? "MP3" : "AAC"))
        }
        if versions.isEmpty, let hls, case .media(let playlist)? = try? M3U8Parser.parse(try await page.text(at: hls), base: hls),
           let version = HLSVersions.audioVersion(of: playlist, language: nil, codecs: ["mp4a.40.2"]) {
            versions.append(version)
        }
        guard !versions.isEmpty else { throw SiteReaderError.unreadable }
        return [SiteVideo(
            label: AudioTrack.label(artist: owner, title: show.text("name")), thumbnail: thumbnail, duration: jsonNumber(show["audioLength"]), versions: versions
        )]
    }
}
