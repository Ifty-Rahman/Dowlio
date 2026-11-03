import Foundation

struct PlayerSetup {
    struct Source {
        var address: String
        var height: Int?
        var type: String?
    }

    struct Found {
        var title: String?
        var poster: String?
        var duration: Double?
        var sources: [Source] = []

        func video(base: URL) -> SiteVideo? {
            var versions: [Version] = []
            var streams: [URL] = []
            for source in sources {
                guard let url = HTMLReader.resolve(ScriptMedia.unescaped(source.address), against: base) else { continue }
                let type = source.type?.lowercased() ?? ""
                if DASHVersions.isStream(url, contentType: type) || type.contains("mpegurl") || type == "hls" || type == "dash" {
                    if !streams.contains(url) { streams.append(url) }
                } else if MediaFile.kind(of: url, contentType: type.contains("/") ? type : nil) != nil || type.hasPrefix("video") {
                    guard !versions.contains(where: { $0.source.url == url }) else { continue }
                    versions.append(Version(
                        source: .file(url), contentType: type.contains("/") ? type : nil,
                        height: source.height ?? MediaFile.height(in: url.path), codecs: MediaFile.codecs(in: url.path)
                    ))
                }
            }
            guard !versions.isEmpty || !streams.isEmpty else { return nil }
            return SiteVideo(
                label: title.map(ScriptMedia.unescaped).flatMap { $0.isEmpty ? nil : PostLabel.shorten($0) },
                thumbnail: poster.flatMap { HTMLReader.resolve(ScriptMedia.unescaped($0), against: base) },
                duration: duration.flatMap { $0 > 0 ? $0 : nil }, versions: versions, streams: streams
            )
        }
    }

    private let text: String

    init(_ text: String) {
        self.text = text
    }

    func video(base: URL) -> SiteVideo? {
        var found = Found()
        let sourceObjects = Self.innermostObjects(in: text).filter { Self.value("file", in: $0) != nil || Self.value("src", in: $0) != nil }
        for object in sourceObjects {
            guard let address = Self.value("file", in: object) ?? Self.value("src", in: object) else { continue }
            let label = Self.value("label", in: object) ?? Self.value("res", in: object) ?? Self.value("quality", in: object)
            let height = (Self.value("height", in: object) ?? Self.value("size", in: object)).flatMap { Int($0) } ?? label.flatMap(MediaFile.height(in:))
            found.sources.append(Source(address: address, height: height, type: Self.value("type", in: object)))
        }
        for key in ["file", "src", "source"] {
            if let address = Self.value(key, in: text), !found.sources.contains(where: { $0.address == address }), Self.looksLikeMedia(address) {
                found.sources.append(Source(address: address))
            }
        }
        for address in Self.listedSources(in: text) where !found.sources.contains(where: { $0.address == address }) {
            found.sources.append(Source(address: address))
        }
        found.title = Self.value("title", in: text)
        found.poster = Self.value("image", in: text) ?? Self.value("poster", in: text)
        found.duration = Self.value("duration", in: text).flatMap { Double($0) }
        return found.video(base: base)
    }

    private static func looksLikeMedia(_ address: String) -> Bool {
        let path = (URL(string: ScriptMedia.unescaped(address))?.path ?? address).lowercased()
        return [".m3u8", ".mpd", ".mp4", ".m4v", ".webm", ".mov", ".mp3", ".m4a"].contains { path.hasSuffix($0) }
    }

    private static let keys = ["file", "src", "source", "label", "res", "quality", "height", "size", "type", "title", "image", "poster", "duration"]
    private static let keyedValues: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: keys.map { key in
        (key, try! NSRegularExpression(
            pattern: #"["']?\b"# + key + #"["']?\s*:\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|(-?[\d.]+)\b)"#
        ))
    })
    private static let sourcesList = try! NSRegularExpression(pattern: #"["']?\bsources["']?\s*:\s*\[([^\]{}]*)\]"#)
    private static let quotedItem = try! NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'"#)
    private static let innermostObject = try! NSRegularExpression(pattern: #"\{[^{}]*\}"#)
    private static let videoJSElement = try! NSRegularExpression(pattern: #"<video-js\b([^>]*)>(.*?)</video-js>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let longestSetup = 200_000

    static func value(_ key: String, in text: String) -> String? {
        guard let pattern = keyedValues[key] else { return nil }
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map(ns.substring(with:))
    }

    private static func listedSources(in text: String) -> [String] {
        let ns = text as NSString
        guard let match = sourcesList.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return [] }
        let list = ns.substring(with: match.range(at: 1))
        let inner = list as NSString
        return quotedItem.matches(in: list, range: NSRange(location: 0, length: inner.length)).compactMap { found in
            (1...2).lazy.map { found.range(at: $0) }.first { $0.location != NSNotFound }.map(inner.substring(with:))
        }
    }

    static func objects(in html: String, after calls: [NSRegularExpression]) -> [String] {
        let ns = html as NSString
        var found: [String] = []
        for call in calls {
            for match in call.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let start = match.range.location + match.range.length
                guard start < ns.length, ns.character(at: start) == openBrace, let object = balancedObject(in: ns, from: start) else { continue }
                found.append(object)
            }
        }
        return found
    }

    static func attributeValues(_ name: String, in html: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(["'])(.*?)\1"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { HTMLReader.decode(ns.substring(with: $0.range(at: 2))) }
    }

    static func videoJSTags(in html: String, base: URL) -> [SiteVideo] {
        let ns = html as NSString
        return videoJSElement.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let attributes = HTMLReader.tags(in: "<video" + ns.substring(with: match.range(at: 1)) + ">", named: ["video"]).first?.attributes ?? [:]
            var setup = Found()
            setup.poster = attributes["poster"]
            setup.title = attributes["title"] ?? attributes["aria-label"]
            if let own = attributes["src"] { setup.sources.append(Source(address: own, type: attributes["type"])) }
            for source in HTMLReader.tags(in: ns.substring(with: match.range(at: 2)), named: ["source"]) {
                guard let address = source.attributes["src"] else { continue }
                setup.sources.append(Source(address: address, height: source.attributes["res"].flatMap { Int($0) } ?? source.attributes["label"].flatMap(MediaFile.height(in:)), type: source.attributes["type"]))
            }
            return setup.video(base: base)
        }
    }

    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let quotes: Set<UInt16> = [UInt16(UInt8(ascii: "\"")), UInt16(UInt8(ascii: "'")), UInt16(UInt8(ascii: "`"))]
    private static let openBrace = UInt16(UInt8(ascii: "{"))
    private static let closeBrace = UInt16(UInt8(ascii: "}"))

    private static func balancedObject(in text: NSString, from start: Int) -> String? {
        var depth = 0
        var quote: UInt16?
        var index = start
        let limit = min(text.length, start + longestSetup)
        while index < limit {
            let character = text.character(at: index)
            if let open = quote {
                if character == backslash { index += 1 } else if character == open { quote = nil }
            } else if quotes.contains(character) {
                quote = character
            } else if character == openBrace {
                depth += 1
            } else if character == closeBrace {
                depth -= 1
                if depth == 0 { return text.substring(with: NSRange(location: start, length: index - start + 1)) }
            }
            index += 1
        }
        return nil
    }

    private static func innermostObjects(in text: String) -> [String] {
        let ns = text as NSString
        return innermostObject.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
