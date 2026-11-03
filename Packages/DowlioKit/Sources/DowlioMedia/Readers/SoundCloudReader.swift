import Foundation

public struct SoundCloudReader: SiteReader {
    public let name = "SoundCloud"
    private let hosts: Set<String>
    private let api: URL

    private static let reserved: Set<String> = [
        "discover", "you", "upload", "pages", "stream", "charts", "search", "settings", "popular", "tags", "feed", "messages", "notifications", "people", "terms-of-use",
    ]
    private static let profileSections: Set<String> = ["sets", "likes", "tracks", "albums", "reposts", "followers", "following", "popular-tracks", "comments", "spotlight"]

    public init(hosts: Set<String> = ["soundcloud.com"], api: URL = URL(string: "https://api-v2.soundcloud.com/")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && (isShortLink(page) || post(in: page) != nil)
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        guard parts.count == 2, !Self.reserved.contains(parts[0].lowercased()), !Self.profileSections.contains(parts[1].lowercased()) else { return nil }
        return parts.joined(separator: "/")
    }

    private func isShortLink(_ page: URL) -> Bool {
        page.host(percentEncoded: false)?.lowercased().hasPrefix("on.") == true && page.pathComponents.count == 2
    }

    private static let clientID = try! NSRegularExpression(pattern: #"client_id\s*[:=]\s*"([a-zA-Z0-9]{20,})""#)
    private static let scriptAddress = try! NSRegularExpression(pattern: #"<script[^>]+src="([^"]+)""#)

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        let client = try await clientID(for: page)
        var resolve = URLComponents(url: api.appending(path: "resolve"), resolvingAgainstBaseURL: false)
        resolve?.queryItems = [URLQueryItem(name: "url", value: page.url.absoluteString), URLQueryItem(name: "client_id", value: client)]
        guard let address = resolve?.url, let track = try await page.json(at: address) as? [String: Any] else { return [] }
        let authorization = track.text("track_authorization")
        var versions: [Version] = []
        for transcoding in (track.object("media") ?? [:]).objects("transcodings") where transcoding["snipped"] as? Bool != true {
            guard let version = try? await version(of: transcoding, client: client, authorization: authorization, page: page) else { continue }
            versions.append(version)
        }
        guard !versions.isEmpty else { return [] }
        let artwork = track.text("artwork_url")?.replacingOccurrences(of: "-large.", with: "-t500x500.")
        return [SiteVideo(
            label: AudioTrack.label(artist: track.object("user")?.text("username"), title: track.text("title")),
            thumbnail: URL(json: artwork), duration: jsonNumber(track["duration"]).map { $0 / 1000 }, versions: versions
        )]
    }

    private func clientID(for page: SitePage) async throws -> String {
        let html = try await page.loadedHTML()
        if let found = AudioTrack.capture(Self.clientID, in: html) { return found }
        let ns = html as NSString
        let scripts = Self.scriptAddress.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range(at: 1)), relativeTo: page.url)?.absoluteURL }
        for script in scripts.reversed() {
            if let found = AudioTrack.capture(Self.clientID, in: (try? await page.text(at: script)) ?? "") { return found }
        }
        throw SiteReaderError.unreadable
    }

    private func version(of transcoding: [String: Any], client: String, authorization: String?, page: SitePage) async throws -> Version? {
        guard let format = transcoding.object("format"), let protocolName = format.text("protocol"), let mime = format.text("mime_type")?.lowercased(),
              var address = transcoding.text("url").flatMap({ URLComponents(string: $0) }) else { return nil }
        let progressive = protocolName == "progressive" && mime.hasPrefix("audio/mpeg")
        let segmented = protocolName == "hls" && mime.hasPrefix("audio/mp4")
        guard progressive || segmented else { return nil }
        address.queryItems = (address.queryItems ?? []) + [URLQueryItem(name: "client_id", value: client)]
            + (authorization.map { [URLQueryItem(name: "track_authorization", value: $0)] } ?? [])
        guard let location = address.url, let reply = try await page.json(at: location) as? [String: Any], let media = URL(json: reply["url"]) else { return nil }
        if progressive { return Version(source: .file(media), contentType: "audio/mpeg", codecs: "MP3") }
        guard case .media(let playlist) = try M3U8Parser.parse(try await page.text(at: media), base: media) else { return nil }
        return HLSVersions.audioVersion(of: playlist, language: nil, codecs: ["mp4a.40.2"])
    }
}
