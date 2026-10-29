import Foundation

enum ScriptMedia {
    private static let mostAddresses = 24
    private static let setupKeys = ["file", "src", "source", "sources", "hls", "hlsUrl", "dash", "dashUrl", "video_url", "contentUrl"]
    private static let sourceKeys: Set<String> = ["src", "source", "sources"]
    private static let mediaExtensions = "m3u8|mpd|mp4|m4v|mov|webm|m4a|mp3|aac"
    private static let notMedia: Set<String> = ["js", "mjs", "css", "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico", "html", "htm", "php", "json", "xml", "woff", "woff2", "ttf"]

    static func addresses(in html: String, base: URL) -> [URL] {
        var found: [URL] = []
        for text in texts(in: html) {
            for value in values(in: unescaped(text)) {
                guard found.count < mostAddresses, let url = HTMLReader.resolve(value, against: base), !found.contains(url) else { continue }
                found.append(url)
            }
        }
        return found
    }

    private static let scriptTag = try! NSRegularExpression(pattern: #"<script\b([^>]*)>"#, options: [.caseInsensitive])
    private static let dataAttribute = try! NSRegularExpression(pattern: #"\bdata-[\w-]+\s*=\s*(["'])(.*?)\1"#, options: [.caseInsensitive])
    private static let percentEncodedAddress = try! NSRegularExpression(pattern: #"https?%3A%2F%2F[^"'\s<>]+"#, options: [.caseInsensitive])

    private static func texts(in html: String) -> [String] {
        let scripts = inlineScripts(in: html)
        let attributes = captures(2, of: dataAttribute, in: html).map(HTMLReader.decode)
        return scripts + scripts.flatMap(PackedScript.unpacked) + attributes
    }

    private static func inlineScripts(in html: String) -> [String] {
        let ns = html as NSString
        var scripts: [String] = []
        var searchFrom = 0
        while searchFrom < ns.length,
              let tag = scriptTag.firstMatch(in: html, range: NSRange(location: searchFrom, length: ns.length - searchFrom)) {
            let start = tag.range.location + tag.range.length
            let end = ns.range(of: "</script", options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
            let close = end.location == NSNotFound ? ns.length : end.location
            if ns.substring(with: tag.range(at: 1)).range(of: #"(^|\s)src\s*="#, options: [.regularExpression, .caseInsensitive]) == nil {
                scripts.append(ns.substring(with: NSRange(location: start, length: close - start)))
            }
            searchFrom = close
        }
        return scripts
    }

    private static func unescaped(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"\/"#, with: "/")
        for (escape, character) in [("\\u002F", "/"), ("\\u002f", "/"), ("\\u0026", "&"), ("\\u003A", ":"), ("\\u003a", ":"), ("\\u003D", "="), ("\\u003d", "=")] {
            text = text.replacingOccurrences(of: escape, with: character)
        }
        text = HTMLReader.decode(text)
        let ns = text as NSString
        var decoded = text
        for match in percentEncodedAddress.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let piece = ns.substring(with: match.range)
            guard let plain = piece.removingPercentEncoding, let range = Range(match.range, in: decoded) else { continue }
            decoded.replaceSubrange(range, with: plain)
        }
        return decoded
    }

    private static func values(in text: String) -> [String] {
        captures(1, of: quotedMediaAddress, in: text) + captures(1, of: setupValue, in: text).filter(isPlayable)
    }

    private static func isPlayable(_ value: String) -> Bool {
        guard value.hasPrefix("http") || value.hasPrefix("/") else { return false }
        let path = URL(string: value)?.path ?? value
        let ext = (path as NSString).pathExtension.lowercased()
        return !notMedia.contains(ext)
    }

    private static let quotedMediaAddress = try! NSRegularExpression(
        pattern: #"["']([^"'\s<>]+?\.(?:"# + mediaExtensions + #")(?:\?[^"'\s<>]*)?)["']"#, options: [.caseInsensitive]
    )
    private static let setupValue = try! NSRegularExpression(
        pattern: #"["']?\b(?:"# + setupKeys.filter { !sourceKeys.contains($0) }.joined(separator: "|") + #")["']?\s*[:=]\s*["']([^"'\s<>]+)["']"#
    )

    private static func captures(_ group: Int, of expression: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            match.range(at: group).location == NSNotFound ? nil : ns.substring(with: match.range(at: group))
        }
    }
}

enum PackedScript {
    private static let packedCall = try! NSRegularExpression(
        pattern: #"\}\s*\(\s*'((?:\\.|[^'\\])*)'\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*'((?:\\.|[^'\\])*)'\.split\(\s*'\|'\s*\)"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let word = try! NSRegularExpression(pattern: #"\b\w+\b"#)
    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func unpacked(_ script: String) -> [String] {
        guard script.contains("eval(function(p,a,c,k,e,") else { return [] }
        let ns = script as NSString
        return packedCall.matches(in: script, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let payload = unquoted(ns.substring(with: match.range(at: 1)))
            guard let radix = Int(ns.substring(with: match.range(at: 2))), (2...62).contains(radix) else { return nil }
            let words = unquoted(ns.substring(with: match.range(at: 4))).components(separatedBy: "|")
            return substituted(payload, radix: radix, words: words)
        }
    }

    private static func substituted(_ payload: String, radix: Int, words: [String]) -> String {
        let ns = payload as NSString
        var result = ""
        var last = 0
        for match in word.matches(in: payload, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let token = ns.substring(with: match.range)
            if let index = number(token, radix: radix), words.indices.contains(index), !words[index].isEmpty {
                result += words[index]
            } else {
                result += token
            }
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    private static func number(_ token: String, radix: Int) -> Int? {
        var value = 0
        for character in token {
            guard let digit = digits.firstIndex(of: character), digit < radix else { return nil }
            value = value * radix + digit
            if value > 1_000_000 { return nil }
        }
        return value
    }

    private static func unquoted(_ text: String) -> String {
        text.replacingOccurrences(of: #"\'"#, with: "'").replacingOccurrences(of: #"\\"#, with: #"\"#)
    }
}
