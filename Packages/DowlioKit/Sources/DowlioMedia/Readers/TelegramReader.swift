import Foundation

public struct TelegramReader: SiteReader {
    public let name = "Telegram"
    private let hosts: Set<String>
    private let embeds: URL

    public init(hosts: Set<String> = ["t.me", "telegram.me"], embeds: URL = URL(string: "https://t.me")!) {
        self.hosts = hosts
        self.embeds = embeds
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst()).filter { $0 != "s" }
        guard parts.count == 2, parts[1].allSatisfy(\.isNumber), parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return parts.joined(separator: "/")
    }

    private static let video = try! NSRegularExpression(pattern: #"<video\b[^>]*\bsrc="([^"]+)""#, options: [.caseInsensitive])
    private static let thumb = try! NSRegularExpression(pattern: #"message_video_thumb"[^>]*background-image:url\('([^']+)'\)"#)
    private static let duration = try! NSRegularExpression(pattern: #"message_video_duration[^>]*>(\d+(?::\d{2}){1,2})<"#)
    private static let text = try! NSRegularExpression(pattern: #"tgme_widget_message_text[^>]*>(.*?)</div>"#, options: [.dotMatchesLineSeparators])
    private static let owner = try! NSRegularExpression(pattern: #"tgme_widget_message_owner_name"[^>]*><span[^>]*>([^<]*)<"#)

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let post = post(in: page.url), var address = URLComponents(url: embeds.appending(path: post), resolvingAgainstBaseURL: false) else { return [] }
        address.queryItems = [URLQueryItem(name: "embed", value: "1"), URLQueryItem(name: "mode", value: "tme"), URLQueryItem(name: "single", value: "1")]
        guard let url = address.url else { return [] }
        let html = try await page.text(at: url)
        func captures(_ pattern: NSRegularExpression) -> [String] {
            let ns = html as NSString
            return pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { HTMLReader.decode(ns.substring(with: $0.range(at: 1))) }
        }
        let words = captures(Self.text).first?.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let label = PostLabel.of(text: words, author: captures(Self.owner).first)
        let thumbnails = captures(Self.thumb)
        let lengths = captures(Self.duration)
        return captures(Self.video).enumerated().compactMap { index, source in
            guard let video = URL(string: source) else { return nil }
            return SiteVideo(
                label: label, thumbnail: thumbnails.indices.contains(index) ? URL(string: thumbnails[index]) : nil,
                duration: lengths.indices.contains(index) ? Self.seconds(lengths[index]) : nil,
                versions: [Version(source: .file(video), contentType: "video/mp4")]
            )
        }
    }

    private static func seconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        return parts.isEmpty ? nil : parts.reduce(0) { $0 * 60 + $1 }
    }
}
