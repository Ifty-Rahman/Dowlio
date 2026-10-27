import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

final class ReaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var logged: [ReaderFailure] = []

    var failures: [ReaderFailure] { lock.withLock { logged } }

    func note(_ failure: ReaderFailure) {
        lock.withLock { logged.append(failure) }
    }
}

struct ReaderSite {
    let site: Site
    let log = ReaderLog()

    init(_ makeReader: (TestServer) -> any SiteReader) async throws {
        let server = try await TestServer()
        let engine = DownloadEngine(configuration: .fast)
        let log = log
        let analyzer = PageAnalyzer(readers: [makeReader(server)], readerFailed: { log.note($0) }) { url, options in
            try await engine.inspect(url, options: options)
        }
        site = Site(server: server, analyzer: analyzer)
    }

    var host: String { site.url("/").host() ?? "" }

    func url(_ path: String) -> URL { site.url(path) }

    func serve(fixture name: String, at path: String, replacing placeholders: [String: String] = [:]) throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Readers/\(name)", withExtension: nil))
        var text = try String(contentsOf: url, encoding: .utf8)
        for (placeholder, value) in placeholders { text = text.replacingOccurrences(of: placeholder, with: value) }
        let type = name.hasSuffix(".html") ? "text/html; charset=utf-8" : "application/json"
        site.server.serve(TestServer.File(data: Data(text.utf8), headers: ["Content-Type": type]), at: path)
    }

    func candidates(_ path: String, page: (inout SentPage) -> Void = { _ in }) async throws -> [Candidate] {
        let found = try await site.analyze(path, page: page)
        guard case .found(let candidates) = found.withoutExtractedAudio else {
            Issue.record("not found: \(found)")
            return []
        }
        return candidates
    }
}

enum PageFixture {
    static func html(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Pages/\(name)", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func embedded(_ key: String, in name: String) throws -> [String: Any] {
        let html = try html(name)
        let start = try #require(html.range(of: "data-sjs>")).upperBound
        let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        let page = try JSONSerialization.jsonObject(with: Data(html[start..<end].utf8))
        return try #require(first(key, in: page) as? [String: Any])
    }

    static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    private static func first(_ key: String, in value: Any) -> Any? {
        if let object = value as? [String: Any] {
            if let found = object[key] { return found }
            return object.values.lazy.compactMap { first(key, in: $0) }.first
        }
        return (value as? [Any])?.lazy.compactMap { first(key, in: $0) }.first
    }
}
