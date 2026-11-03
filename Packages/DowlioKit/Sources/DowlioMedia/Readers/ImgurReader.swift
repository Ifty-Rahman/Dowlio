import Foundation

public struct ImgurReader: SiteReader {
    public let name = "Imgur"
    private let hosts: Set<String>

    public init(hosts: Set<String> = ["imgur.com"]) {
        self.hosts = hosts
    }

    public func recognises(_ page: URL) -> Bool {
        page.isOn(hosts) && post(in: page) != nil
    }

    public func post(in page: URL) -> String? {
        let parts = Array(page.pathComponents.dropFirst())
        let last = parts.count == 1 ? parts[0] : parts.count == 2 && ["gallery", "a", "t"].contains(parts[0]) ? parts[1] : nil
        guard let id = last.map({ ($0 as NSString).deletingPathExtension }).flatMap({ $0.split(separator: "-").last.map(String.init) }) else { return nil }
        let looksLikeAnID = id.allSatisfy { $0.isLetter || $0.isNumber } && id.contains { $0.isUppercase || $0.isNumber }
        return (5...8).contains(id.count) && looksLikeAnID ? id : nil
    }

    private static let postData = try! NSRegularExpression(pattern: #"postDataJSON\s*=\s*("(?:\\.|[^"\\])*")"#)

    public func read(_ page: SitePage) async throws -> [SiteVideo] {
        guard let id = post(in: page.url) else { return [] }
        if ["mp4", "gifv", "webm"].contains(page.url.pathExtension.lowercased()), let direct = URL(string: "https://i.imgur.com/\(id).mp4") {
            return [SiteVideo(versions: [Version(source: .file(direct), contentType: "video/mp4")])]
        }
        guard let html = page.html else { return [] }
        let ns = html as NSString
        guard let match = Self.postData.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              let text = try JSONSerialization.jsonObject(with: Data(ns.substring(with: match.range(at: 1)).utf8), options: [.fragmentsAllowed]) as? String,
              let post = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        let title = post.text("title")
        return post.objects("media").compactMap { media -> SiteVideo? in
            guard media.text("type") == "video" || ["mp4", "webm"].contains(media.text("ext") ?? ""), let url = URL(json: media["url"]) else { return nil }
            let metadata = media.object("metadata") ?? [:]
            let size = jsonNumber(media["size"]).map(Int64.init)
            return SiteVideo(
                label: metadata.text("title") ?? title, duration: jsonNumber(metadata["duration"]),
                versions: [Version(source: .file(url), contentType: "video/mp4", totalBytes: size, height: shorterSide(media["width"], media["height"]))]
            )
        }
    }
}
