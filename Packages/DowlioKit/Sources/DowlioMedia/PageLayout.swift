import DowlioCore
import Foundation

struct PageLayout {
    struct Bucket {
        var player: ScannedPlayer?
        var files: [ScannedMedia] = []
        var streams: [URL] = []
        var isOther = false

        var isEmpty: Bool { files.isEmpty && streams.isEmpty }

        var unprobed: [WatchedRequest] {
            files.map { WatchedRequest(url: $0.url, kind: .file) } + streams.map { WatchedRequest(url: $0, kind: .manifest) }
        }
    }

    static let probedAtOnce = 5

    private(set) var buckets: [Bucket] = []
    let isFeed: Bool

    init(page: SentPage, players: [(group: Int?, sources: [ScannedMedia])], streams: [URL]) {
        let holdingMedia = Set(players.compactMap(\.group))
        let shown = page.players.filter { player in
            player.isPlaying || player.visibility > 0 || player.poster != nil || player.duration != nil || holdingMedia.contains(player.group)
        }
        isFeed = shown.count > 1
        var byGroup: [Int: Bucket] = [:]
        for player in shown { byGroup[player.group] = Bucket(player: player) }
        var loose: [Bucket] = []
        for (group, sources) in players {
            if let group, byGroup[group] != nil {
                byGroup[group]?.files += sources
            } else {
                loose.append(Bucket(files: sources, isOther: isFeed))
            }
        }
        var other = Bucket(isOther: true)
        var unplaced: [URL] = []
        for url in streams {
            let referrer = page.watched.first { $0.url == url }?.referrer
            if let group = Self.matchingPlayer(for: url, in: shown) ?? Self.framingPlayer(for: referrer, in: shown) {
                byGroup[group]?.streams.append(url)
            } else {
                unplaced.append(url)
            }
        }
        if isFeed {
            other.streams = unplaced
        } else if let only = shown.first {
            byGroup[only.group]?.streams += unplaced
        } else if !unplaced.isEmpty {
            loose.append(Bucket(streams: unplaced))
        }
        let ordered = shown.sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            if a.visibility != b.visibility { return a.visibility > b.visibility }
            return a.group < b.group
        }
        buckets = (ordered.compactMap { byGroup[$0.group] } + loose + [other]).filter { !$0.isEmpty }
    }

    static func matchingPlayer(for url: URL, in players: [ScannedPlayer]) -> Int? {
        let wanted = ids(in: url)
        guard !wanted.isEmpty else { return nil }
        return players.first { player in player.poster.map { !ids(in: $0).isDisjoint(with: wanted) } ?? false }?.group
    }

    static func framingPlayer(for referrer: URL?, in players: [ScannedPlayer]) -> Int? {
        guard let origin = referrer?.webOrigin else { return nil }
        let framed = players.filter { $0.origin?.webOrigin == origin }
        if framed.count == 1 { return framed[0].group }
        let playing = framed.filter(\.isPlaying)
        return playing.count == 1 ? playing[0].group : nil
    }

    static func ids(in url: URL) -> Set<String> {
        let text = url.path + "?" + (url.query ?? "")
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(tokens.filter { $0.count >= 6 && $0.filter(\.isNumber).count >= 5 })
    }

    var onScreen: Bucket? {
        guard isFeed, let first = buckets.first, let player = first.player, player.isPlaying || player.visibility > 0 else { return nil }
        return first
    }
}
