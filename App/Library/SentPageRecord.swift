import DowlioCore
import DowlioMedia
import Foundation
import os

#if DEBUG
enum SentPageRecord {
    private static let failures = OSAllocatedUnfairLock(initialState: [ReaderFailure]())

    static func note(_ failure: ReaderFailure) {
        failures.withLock { $0.append(failure) }
    }
    static var file: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Dowlio/last-sent-page.json")
    }

    static func recording(_ page: SentPage, _ analysis: AsyncStream<PageAnalysis>) -> AsyncStream<PageAnalysis> {
        AsyncStream { continuation in
            let task = Task {
                var last: PageAnalysis?
                for await update in analysis {
                    last = update
                    continuation.yield(update)
                }
                write(page, last)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func read(_ file: URL) -> SentPage? {
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (record["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        func list(_ key: String) -> [[String: Any]] { record[key] as? [[String: Any]] ?? [] }
        func link(_ entry: [String: Any], _ key: String) -> URL? { (entry[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        func number(_ entry: [String: Any], _ key: String) -> Double? { (entry[key] as? Double).flatMap { $0 > 0 ? $0 : nil } }
        let scan = list("scan").compactMap { entry -> ScannedMedia? in
            guard let address = link(entry, "url") else { return nil }
            return ScannedMedia(
                url: address, kind: (entry["kind"] as? String).flatMap(ScannedMedia.Kind.init(rawValue:)) ?? .video,
                poster: link(entry, "poster"), duration: number(entry, "duration"),
                group: (entry["group"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            )
        }
        let players = list("players").compactMap { entry -> ScannedPlayer? in
            guard let group = entry["group"] as? Int else { return nil }
            return ScannedPlayer(
                group: group, label: (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }, poster: link(entry, "poster"),
                duration: number(entry, "duration"), isPlaying: entry["playing"] as? Bool ?? false, visibility: entry["visible"] as? Double ?? 0,
                origin: link(entry, "origin")
            )
        }
        let watched = list("watched").compactMap { entry -> WatchedRequest? in
            guard let address = link(entry, "url"), let kind = (entry["kind"] as? String).flatMap(WatchedRequest.Kind.init(rawValue:)) else { return nil }
            return WatchedRequest(
                url: address, kind: kind, contentType: (entry["contentType"] as? String).flatMap { $0.isEmpty ? nil : $0 }, referrer: link(entry, "referrer")
            )
        }
        return SentPage(
            url: url, title: (record["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }, browser: "Replay",
            scan: scan, players: players, watched: watched, throughDowlioConnect: true
        )
    }

    private static func write(_ page: SentPage, _ analysis: PageAnalysis?) {
        let readerFailures = failures.withLock { noted in
            defer { noted = [] }
            return noted.map { "\($0.reader) on \($0.site): \($0.reason)" }
        }
        var record: [String: Any] = [
            "url": page.url.absoluteString,
            "title": page.title ?? "",
            "cookieCount": page.cookies.count,
            "userAgent": page.userAgent ?? "",
            "scan": page.scan.map {
                ["url": $0.url.absoluteString, "kind": $0.kind.rawValue, "height": $0.height ?? 0, "group": $0.group ?? -1, "codecs": $0.codecs ?? "",
                 "poster": $0.poster?.absoluteString ?? "", "duration": $0.duration ?? -1]
            },
            "players": page.players.map {
                ["group": $0.group, "label": $0.label ?? "", "poster": $0.poster?.absoluteString ?? "", "duration": $0.duration ?? -1,
                 "playing": $0.isPlaying, "visible": $0.visibility, "origin": $0.origin?.absoluteString ?? ""]
            },
            "readerFailures": readerFailures,
            "watched": page.watched.map {
                ["url": $0.url.absoluteString, "kind": $0.kind.rawValue, "contentType": $0.contentType ?? "", "referrer": $0.referrer?.absoluteString ?? ""]
            },
        ]
        switch analysis {
        case .found(let candidates):
            record["candidates"] = candidates.map { candidate in
                [
                    "label": candidate.label,
                    "duration": candidate.duration ?? -1,
                    "versions": candidate.versions.map { version -> [String: Any] in
                        let source: String = if case .media = version.source { "stream" } else { "file" }
                        return [
                            "source": source, "url": version.source.url.absoluteString, "height": version.height ?? 0,
                            "codecs": version.codecs ?? "", "contentType": version.contentType ?? "", "bytes": version.totalBytes ?? -1,
                            "referrer": version.referrer?.absoluteString ?? "",
                        ]
                    },
                ] as [String: Any]
            }
        case .plainFile(let url):
            record["plainFile"] = url.absoluteString
        case .needsSignIn:
            record["needsSignIn"] = true
        case .blocked:
            record["blocked"] = true
        case .needsTools:
            record["needsTools"] = true
        case .toolsChanged:
            record["toolsChanged"] = true
        case .ytdlpFailed(let failure):
            record["ytdlpFailed"] = String(describing: failure)
        case .playlist(let listing):
            record["playlist"] = ["title": listing.title, "entries": listing.entries.count, "total": listing.total, "heights": listing.heights ?? []] as [String: Any]
        case .looking, .checkingForMore, .playing, nil:
            record["unfinished"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
#endif
