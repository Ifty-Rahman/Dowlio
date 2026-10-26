import DowlioCore
import DowlioMedia
import Foundation

#if DEBUG
enum SentPageRecord {
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

    private static func write(_ page: SentPage, _ analysis: PageAnalysis?) {
        var record: [String: Any] = [
            "url": page.url.absoluteString,
            "title": page.title ?? "",
            "cookieCount": page.cookies.count,
            "scan": page.scan.map { ["url": $0.url.absoluteString, "kind": $0.kind.rawValue, "height": $0.height ?? 0, "group": $0.group ?? -1, "codecs": $0.codecs ?? ""] },
            "watched": page.watched.map { ["url": $0.url.absoluteString, "kind": $0.kind.rawValue, "contentType": $0.contentType ?? ""] },
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
                        ]
                    },
                ] as [String: Any]
            }
        case .plainFile(let url):
            record["plainFile"] = url.absoluteString
        case .needsSignIn:
            record["needsSignIn"] = true
        case .looking, .playing, nil:
            record["unfinished"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
#endif
