import Foundation

struct HTMLReader {
    private(set) var media: [ScannedMedia] = []
    private(set) var title: String?
    private(set) var image: URL?
    private(set) var duration: Double?

    init(_ html: String, base: URL) {
        var pageTitle: String?
        var openMedia = ScannedMedia.Kind.video
        var players = 0
        var player: Int?
        for tag in Self.tags(in: html) {
            let attributes = tag.attributes
            func link(_ name: String) -> URL? { attributes[name].flatMap { Self.resolve($0, against: base) } }
            switch tag.name {
            case "video", "audio":
                openMedia = tag.name == "audio" ? .audio : .video
                players += 1
                player = players
                if let url = link("src") {
                    add(ScannedMedia(url: url, kind: openMedia, poster: link("poster"), group: player))
                }
                if image == nil { image = link("poster") }
            case "source":
                guard let url = link("src") else { continue }
                let type = attributes["type"]?.lowercased() ?? ""
                add(ScannedMedia(url: url, kind: type.hasPrefix("audio/") ? .audio : type.hasPrefix("video/") ? .video : openMedia, group: player))
            case "/video", "/audio":
                player = nil
            case "a":
                guard let url = link("href"), let kind = MediaFile.kind(of: url) else { continue }
                add(ScannedMedia(url: url, kind: kind))
            case "meta":
                readMeta(attributes, base: base)
            default:
                continue
            }
        }
        if let range = html.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let inner = html[range].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            pageTitle = Self.decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for block in Self.jsonLD(in: html) { readJSONLD(block, base: base) }
        if title == nil, let pageTitle, !pageTitle.isEmpty { title = pageTitle }
    }

    private mutating func add(_ found: ScannedMedia) {
        guard !media.contains(where: { $0.url == found.url }) else { return }
        media.append(found)
    }

    private mutating func readMeta(_ attributes: [String: String], base: URL) {
        guard let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
              let content = attributes["content"] else { return }
        switch key {
        case "og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream":
            if let url = Self.resolve(content, against: base), MediaFile.kind(of: url) != .audio || key.hasPrefix("og:video") {
                add(ScannedMedia(url: url, kind: .video))
            }
        case "og:audio", "og:audio:url", "og:audio:secure_url":
            if let url = Self.resolve(content, against: base) { add(ScannedMedia(url: url, kind: .audio)) }
        case "og:image", "twitter:image":
            if image == nil { image = Self.resolve(content, against: base) }
        case "og:title", "twitter:title":
            if title == nil, !content.isEmpty { title = content }
        case "og:duration", "og:video:duration", "video:duration", "duration":
            if duration == nil { duration = Double(content) ?? Self.isoDuration(content) }
        default:
            break
        }
    }

    private mutating func readJSONLD(_ text: String, base: URL) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return }
        for entry in Self.mediaObjects(in: object) {
            let kind: ScannedMedia.Kind = (entry["@type"] as? String) == "AudioObject" ? .audio : .video
            if let content = entry["contentUrl"] as? String, let url = Self.resolve(content, against: base) {
                add(ScannedMedia(url: url, kind: kind))
            }
            if duration == nil, let text = entry["duration"] as? String { duration = Self.isoDuration(text) }
            if image == nil {
                let thumbnail = (entry["thumbnailUrl"] as? String) ?? (entry["thumbnailUrl"] as? [String])?.first
                image = thumbnail.flatMap { Self.resolve($0, against: base) }
            }
            if title == nil, let name = entry["name"] as? String, !name.isEmpty { title = name }
        }
    }

    private static func mediaObjects(in object: Any) -> [[String: Any]] {
        if let list = object as? [Any] { return list.flatMap(mediaObjects) }
        guard let entry = object as? [String: Any] else { return [] }
        let type = entry["@type"] as? String
        let own = type == "VideoObject" || type == "AudioObject" ? [entry] : []
        return own + entry.values.flatMap { value in value is [Any] || value is [String: Any] ? mediaObjects(in: value) : [] }
    }

    struct Tag {
        var name: String
        var attributes: [String: String]
    }

    static func tags(in html: String) -> [Tag] {
        let pattern = try! NSRegularExpression(pattern: #"<(/?video|/?audio|meta|source|a)\b([^>]*)>"#, options: [.caseInsensitive])
        let attribute = try! NSRegularExpression(pattern: #"([A-Za-z_:][-\w:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
        let text = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: text.length)).map { match in
            let name = text.substring(with: match.range(at: 1)).lowercased()
            let body = text.substring(with: match.range(at: 2))
            let inner = body as NSString
            var attributes: [String: String] = [:]
            for found in attribute.matches(in: body, range: NSRange(location: 0, length: inner.length)) {
                let key = inner.substring(with: found.range(at: 1)).lowercased()
                let value = (2...4).lazy.map { found.range(at: $0) }.first { $0.location != NSNotFound }.map(inner.substring(with:)) ?? ""
                if attributes[key] == nil { attributes[key] = decode(value) }
            }
            return Tag(name: name, attributes: attributes)
        }
    }

    static func jsonLD(in html: String) -> [String] {
        let pattern = try! NSRegularExpression(
            pattern: #"<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let text = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) }
    }

    static func resolve(_ value: String, against base: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func isoDuration(_ text: String) -> Double? {
        let pattern = try! NSRegularExpression(pattern: #"^P(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)$"#)
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let parts = (1...3).map { match.range(at: $0).location == NSNotFound ? 0 : Double(ns.substring(with: match.range(at: $0))) ?? 0 }
        let seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return seconds > 0 ? seconds : nil
    }
}
