import Foundation

public struct AnimatedPostReader: SiteReader {
    public let name: String
    private let hosts: Set<String>
    private let postID: @Sendable (URL) -> String?
    private let belongs: @Sendable (URL, String, String) -> Bool
    private let labelKey: String

    public static func giphy(hosts: Set<String> = ["giphy.com"]) -> AnimatedPostReader {
        AnimatedPostReader(name: "Giphy", hosts: hosts, labelKey: "title", postID: { page in
            guard let part = page.pathComponent(after: ["gifs", "embed", "clips", "media"]) else { return nil }
            let id = part.split(separator: "-").last.map(String.init) ?? part
            return id.count >= 10 && id.allSatisfy { $0.isLetter || $0.isNumber } && id.contains { $0.isUppercase || $0.isNumber } ? id : nil
        }, belongs: { url, id, _ in url.pathComponents.contains(id) })
    }

    public static func tenor(hosts: Set<String> = ["tenor.com"]) -> AnimatedPostReader {
        AnimatedPostReader(name: "Tenor", hosts: hosts, labelKey: "content_description", postID: { page in
            guard let part = page.pathComponent(after: ["view"]), let id = part.split(separator: "-").last, id.count >= 6, id.allSatisfy(\.isNumber) else { return nil }
            return String(id)
        }, belongs: { url, _, html in
            guard let shown = Self.ogVideo(in: html), let key = shown.pathComponents.dropFirst().first, key.count > 6 else { return false }
            return url.pathComponents.dropFirst().first?.hasPrefix(String(key.dropLast(6))) == true
        })
    }

    public static func nineGag(hosts: Set<String> = ["9gag.com"]) -> AnimatedPostReader {
        AnimatedPostReader(name: "9GAG", hosts: hosts, labelKey: "title", postID: { page in
            guard let id = page.pathComponent(after: ["gag"]), (6...10).contains(id.count), id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return id
        }, belongs: { url, id, _ in url.lastPathComponent.hasPrefix(id + "_") })
    }

    private init(
        name: String, hosts: Set<String>, labelKey: String, postID: @escaping @Sendable (URL) -> String?,
        belongs: @escaping @Sendable (URL, String, String) -> Bool
    ) {
        self.name = name
        self.hosts = hosts
        self.labelKey = labelKey
        self.postID = postID
        self.belongs = belongs
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && postID(page) != nil
    }

    public func post(in page: URL) -> String? {
        postID(page)
    }

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = postID(page.url), let html = page.html else { return [] }
        let text = Renditions.plain(html)
        let found = Renditions.found(in: text).filter { belongs($0.url, id, html) }
        var seen = Set<String>()
        let versions = found.sorted { ($0.size ?? 0, $0.height ?? 0) > ($1.size ?? 0, $1.height ?? 0) }.compactMap { rendition -> Version? in
            guard seen.insert(PageAnalyzer.withoutQuery(rendition.url)).inserted else { return nil }
            return Version(source: .file(rendition.url), contentType: "video/mp4", totalBytes: rendition.size, height: rendition.height, codecs: rendition.codecs)
        }
        guard !versions.isEmpty else { return [] }
        let label = Renditions.value(labelKey, inObjectWithID: id, in: text).map(HTMLReader.decode)
        return [SiteVideo(label: label, duration: found.compactMap(\.duration).max(), versions: versions)]
    }

    private static func ogVideo(in html: String) -> URL? {
        HTMLReader.tags(in: html, named: ["meta"]).first { $0.attributes["property"] == "og:video" }.flatMap { $0.attributes["content"] }.flatMap(URL.init(string:))
    }
}
