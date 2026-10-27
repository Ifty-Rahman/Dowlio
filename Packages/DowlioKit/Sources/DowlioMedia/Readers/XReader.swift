import Foundation

public struct XReader: SiteReader {
    public let name = "X"
    private let hosts: Set<String>
    private let api: URL

    public init(hosts: Set<String> = ["x.com", "twitter.com"], api: URL = URL(string: "https://cdn.syndication.twimg.com/tweet-result")!) {
        self.hosts = hosts
        self.api = api
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        guard let id = page.pathComponent(after: ["status", "statuses"]) else { return nil }
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url) else { return [] }
        var address = URLComponents(url: api, resolvingAgainstBaseURL: false)
        address?.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "token", value: Self.token(for: id)), URLQueryItem(name: "lang", value: "en")]
        guard let url = address?.url else { return [] }
        guard let tweet = try await page.json(at: url) as? [String: Any] else { throw SiteReaderError.unreadable }
        return videos(in: tweet)
    }

    private func videos(in tweet: [String: Any]) -> [SiteVideo] {
        let user = tweet["user"] as? [String: Any]
        let label = PostLabel.of(text: Self.withoutMediaLinks(tweet["text"] as? String), author: user?["name"] as? String)
        let media = (tweet["mediaDetails"] as? [[String: Any]]) ?? []
        return media.compactMap { video(in: $0, label: label) }
    }

    private func video(in media: [String: Any], label: String?) -> SiteVideo? {
        guard let info = media["video_info"] as? [String: Any], let variants = info["variants"] as? [[String: Any]] else { return nil }
        let duration = jsonNumber(info["duration_millis"]).map { $0 / 1000 }
        var files: [Version] = []
        var streams: [URL] = []
        for variant in variants {
            guard let url = URL(json: variant["url"]) else { continue }
            let type = (variant["content_type"] as? String)?.lowercased() ?? ""
            if type == "video/mp4" {
                let bitrate = jsonNumber(variant["bitrate"])
                let size = bitrate.flatMap { bits in duration.map { Int64(bits * $0 / 8) } }
                files.append(Version(
                    source: .file(url), contentType: "video/mp4", totalBytes: size, isEstimatedSize: size != nil,
                    height: MediaFile.height(in: url.path), codecs: MediaFile.codecs(in: url.path).map { "\($0) + AAC" } ?? "H.264 + AAC"
                ))
            } else if HLSVersions.isPlaylist(url, contentType: type) {
                streams.append(url)
            }
        }
        guard !files.isEmpty || !streams.isEmpty else { return nil }
        return SiteVideo(
            label: label, thumbnail: URL(json: media["media_url_https"]), duration: duration,
            versions: files, streams: files.isEmpty ? streams : []
        )
    }

    private static func withoutMediaLinks(_ text: String?) -> String? {
        text?.replacingOccurrences(of: #"https://t\.co/\w+"#, with: "", options: .regularExpression)
    }

    static func token(for id: String) -> String {
        guard let value = Double(id) else { return "0" }
        let scaled = value / 1e15 * Double.pi
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var whole = scaled.rounded(.down)
        var fraction = scaled - whole
        var integer = ""
        repeat {
            integer.insert(digits[Int(whole.truncatingRemainder(dividingBy: 36))], at: integer.startIndex)
            whole = (whole / 36).rounded(.down)
        } while whole > 0
        var tail = ""
        for _ in 0..<10 where fraction > 0 {
            fraction *= 36
            let digit = Int(fraction)
            tail.append(digits[digit])
            fraction -= Double(digit)
        }
        return (integer + tail).replacingOccurrences(of: "0", with: "")
    }
}
