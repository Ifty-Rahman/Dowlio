import Foundation

public struct PageScan: Equatable, Sendable {
    public static let maximumMedia = 200
    public static let maximumEmbeddedJSON = 40

    public var media: [ScannedMedia]
    public var players: [ScannedPlayer]
    public var embeddedJSON: [String]

    public init(_ object: [String: Any]) {
        let found = ((object["media"] as? [[String: Any]]) ?? []).prefix(Self.maximumMedia).compactMap { entry -> ScannedMedia? in
            guard let value = entry["url"] as? String, value.count <= 8192, let address = URL(string: value), Self.isWebLink(address) else { return nil }
            let poster = (entry["poster"] as? String).flatMap(URL.init(string:)).flatMap { Self.isWebLink($0) ? $0 : nil }
            let duration = (entry["duration"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let kind = (entry["kind"] as? String).flatMap(ScannedMedia.Kind.init(rawValue:)) ?? .video
            let group = (entry["group"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return ScannedMedia(url: address, kind: kind, poster: poster, duration: duration, group: group)
        }
        let players = ((object["players"] as? [[String: Any]]) ?? []).prefix(Self.maximumMedia).compactMap { entry -> ScannedPlayer? in
            guard let group = entry["group"] as? Int, group > 0 else { return nil }
            return ScannedPlayer(
                group: group,
                label: (entry["label"] as? String).flatMap { !$0.isEmpty && $0.count <= 200 ? $0 : nil },
                poster: (entry["poster"] as? String).flatMap(URL.init(string:)).flatMap { Self.isWebLink($0) ? $0 : nil },
                duration: (entry["duration"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                isPlaying: entry["playing"] as? Bool ?? false,
                visibility: (entry["visible"] as? Double).map { min(max($0, 0), 1) } ?? 0,
                origin: (entry["origin"] as? String).flatMap(URL.init(string:)).flatMap { Self.isWebLink($0) ? $0 : nil }
            )
        }
        let embedded = ((object["embeddedJson"] as? [Any]) ?? []).prefix(Self.maximumEmbeddedJSON).compactMap { $0 as? String }
        media = Array(found)
        self.players = Array(players)
        embeddedJSON = Array(embedded)
    }

    public init?(json text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        self.init(object)
    }

    public mutating func join(_ other: PageScan, offsettingGroupsBy offset: Int) {
        media += other.media.map { found in
            var moved = found
            moved.group = found.group.map { $0 + offset }
            return moved
        }
        players += other.players.map { player in
            var moved = player
            moved.group += offset
            return moved
        }
        embeddedJSON += other.embeddedJSON
        media = Array(media.prefix(Self.maximumMedia))
        players = Array(players.prefix(Self.maximumMedia))
        embeddedJSON = Array(embeddedJSON.prefix(Self.maximumEmbeddedJSON))
    }

    public static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }
}
