import Foundation

enum Renditions {
    struct Found {
        var url: URL
        var height: Int?
        var size: Int64?
        var duration: Double?
        var codecs: String?
    }

    private static let object = try! NSRegularExpression(pattern: #"\{[^{}]*\}"#)
    private static let address = try! NSRegularExpression(pattern: #""(\w+)"\s*:\s*"(https?://[^"]+?\.mp4(?:\?[^"]*)?)""#)
    private static let dims = try! NSRegularExpression(pattern: #""dims"\s*:\s*\[\s*(\d+)\s*,\s*(\d+)\s*\]"#)

    private static let numberKeys = ["width", "height", "size", "mp4_size", "duration"]
    private static let numbers: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: numberKeys.map { key in
        (key, try! NSRegularExpression(pattern: #""\#(key)"\s*:\s*"?(\d+(?:\.\d+)?)"?"#))
    })

    static func number(_ key: String, in text: String) -> Double? {
        guard let pattern = numbers[key] else { return nil }
        let ns = text as NSString
        return pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { Double(ns.substring(with: $0.range(at: 1))) }
    }

    static func value(_ key: String, inObjectWithID id: String, in text: String) -> String? {
        let pattern = #""id"\s*:\s*"\#(NSRegularExpression.escapedPattern(for: id))"[^{}]*?"\#(key)"\s*:\s*"([^"]*)""#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[range].firstMatch(of: /"([^"]*)"$/).map { String($0.1) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func plain(_ html: String) -> String {
        ScriptMedia.unescaped(html.replacingOccurrences(of: #"\\/"#, with: "/").replacingOccurrences(of: #"\""#, with: "\""))
    }

    static func found(in text: String) -> [Found] {
        let ns = text as NSString
        return object.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { match -> [Found] in
            let body = ns.substring(with: match.range)
            let inner = body as NSString
            func number(_ key: String) -> Double? { Self.number(key, in: body) }
            var height = shorterSide(number("width"), number("height"))
            if height == nil, let pair = dims.firstMatch(in: body, range: NSRange(location: 0, length: inner.length)) {
                height = shorterSide(inner.substring(with: pair.range(at: 1)), inner.substring(with: pair.range(at: 2)))
            }
            return address.matches(in: body, range: NSRange(location: 0, length: inner.length)).compactMap { found -> Found? in
                let key = inner.substring(with: found.range(at: 1))
                guard let url = URL(string: inner.substring(with: found.range(at: 2))) else { return nil }
                let size = key == "mp4" ? number("mp4_size") : key == "url" ? number("size") : nil
                let codecs = key.lowercased().hasPrefix("h265") ? "HEVC" : key.lowercased().hasPrefix("av1") ? "AV1" : nil
                return Found(url: url, height: height, size: size.map(Int64.init), duration: number("duration").flatMap { $0 > 0 ? $0 : nil }, codecs: codecs)
            }
        }
    }
}
