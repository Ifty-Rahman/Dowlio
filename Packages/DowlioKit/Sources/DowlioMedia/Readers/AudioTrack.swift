import Foundation

enum AudioTrack {
    static func label(artist: String?, title: String?) -> String? {
        let name = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let track = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || track.isEmpty { return track.isEmpty ? (name.isEmpty ? nil : name) : track }
        return "\(name) - \(track)"
    }

    static func capture(_ pattern: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        return pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func first(_ key: String, in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if object[key] != nil { return object }
            return object.values.lazy.compactMap { first(key, in: $0) }.first
        }
        return (value as? [Any])?.lazy.compactMap { first(key, in: $0) }.first
    }
}
