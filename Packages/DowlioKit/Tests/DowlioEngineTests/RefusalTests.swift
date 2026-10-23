import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// Ticket 05: servers that refuse connections, and servers whose range replies can't be used.
@Suite(.timeLimit(.minutes(1)))
struct RefusalTests {
    static let held = 64 * 1024

    /// The host key a learned limit is stored under: host and port.
    private static func host(of server: TestServer) -> String {
        "127.0.0.1:\(server.port)"
    }

    /// 8 MiB plans 8 segments of 1 MiB, too small to split, so no connection is cut short by a
    /// steal and opens a new one before the server sees the old one close.
    @Test func aServerThatAllowsThreeConnectionsEndsWithTheDownloadUsingThree() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 51)
        // Replies hold after a few bytes, so all of them are in flight at once.
        server.serve(.init(data: data, holdAfterBytes: Self.held, maxParallel: 3), at: "/capped.iso")
        let folder = try TestFiles.makeFolder()
        let limits = InMemoryHostLimitStore()
        var configuration = EngineConfiguration.fastWithHolds
        configuration.hostLimits = limits

        let engine = DownloadEngine(configuration: configuration)
        var options = RequestOptions()
        options.connections = 8
        let id = await engine.add(url: server.url(for: "/capped.iso"), to: folder, options: options)

        // Eight connections open; the server admits three and refuses five. Each refusal lowers
        // the limit by one: 8 to 3.
        try await waitUntil { server.refusals(at: "/capped.iso") == 5 && limits.limit(for: Self.host(of: server)) == 3 }
        server.releaseHeldResponses()
        let finished = try await engine.finished(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "capped.iso")) == TestFiles.sha256(data))
        #expect(limits.limit(for: Self.host(of: server)) == 3)
        // Once at three, the download never asked for more than the server allows.
        #expect(server.refusals(at: "/capped.iso") == 5)
        #expect(server.peakParallel(at: "/capped.iso") == 3)
    }

    /// The first download learns that the host allows two connections. The second, from the same
    /// host, plans two segments from the start and is never refused. Its 3 MiB would otherwise
    /// plan three, and 1.5 MiB segments are too small to split.
    @Test func laterDownloadsFromTheSameHostStartWithItsLearnedLimit() async throws {
        let server = try await TestServer()
        let first = TestServer.makeData(size: 8 * 1024 * 1024, seed: 52)
        let second = TestServer.makeData(size: 3 * 1024 * 1024, seed: 59)
        server.serve(.init(data: first, holdAfterBytes: Self.held, maxParallel: 2), at: "/first.iso")
        server.serve(.init(data: second, maxParallel: 2), at: "/second.bin")
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 8

        let engine = DownloadEngine(configuration: .fastWithHolds)
        let firstID = await engine.add(url: server.url(for: "/first.iso"), to: folder, options: options)
        try await waitUntil { server.refusals(at: "/first.iso") == 6 }
        server.releaseHeldResponses()
        #expect(try await engine.finished(firstID).state == .completed)

        let secondID = await engine.add(url: server.url(for: "/second.bin"), to: folder, options: options)
        let finished = try await engine.finished(secondID)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "second.bin")) == TestFiles.sha256(second))
        #expect(server.refusals(at: "/second.bin") == 0)
        let segmentRequests = server.requests.filter { $0.path == "/second.bin" && $0.headers["range"] != "bytes=0-0" }
        #expect(Set(segmentRequests.compactMap { $0.headers["range"] }) == ["bytes=0-1572863", "bytes=1572864-3145727"])
        #expect(segmentRequests.count == 2)
    }

    enum Failure: Sendable, CustomTestStringConvertible {
        case status(Int)
        case reset

        var testDescription: String {
            switch self {
            case .status(let status): "status \(status)"
            case .reset: "a reset connection"
            }
        }
    }

    /// 429, 503 and a reset connection lower the host's limit by one. Other retried failures,
    /// such as a 500, don't.
    @Test(arguments: [
        (Failure.status(429), 3 as Int?),
        (Failure.status(503), 3 as Int?),
        (Failure.reset, 3 as Int?),
        (Failure.status(500), nil as Int?),
    ])
    func refusalsLowerTheHostsLimitByOne(failure: Failure, learned: Int?) async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 53)
        var file = TestServer.File(data: data)
        switch failure {
        case .status(let status): file.failFirst = .init(status: status, count: 1)
        case .reset: file.dropFirst = .init(afterBytes: 64 * 1024, count: 1)
        }
        server.serve(file, at: "/refused.bin")
        let folder = try TestFiles.makeFolder()
        let limits = InMemoryHostLimitStore()
        var configuration = EngineConfiguration.fast
        configuration.hostLimits = limits

        let engine = DownloadEngine(configuration: configuration)
        var options = RequestOptions()
        options.connections = 4
        let id = await engine.add(url: server.url(for: "/refused.bin"), to: folder, options: options)
        let finished = try await engine.finished(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "refused.bin")) == TestFiles.sha256(data))
        #expect(limits.limit(for: Self.host(of: server)) == learned)
    }

    /// Downloads a file whose server behaves as `file` describes, and checks that it completes
    /// with the served bytes, the last request asking for the whole file without a range.
    private func downloadFallsBackToOneConnection(_ file: TestServer.File, name: String) async throws -> TestServer {
        let server = try await TestServer()
        server.serve(file, at: "/\(name)")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/\(name)"), to: folder)
        let finished = try await engine.finished(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: name)) == TestFiles.sha256(file.data))
        let last = try #require(server.requests.last)
        #expect(last.headers["range"] == nil)
        return server
    }

    @Test func aRangeReplyForTheWrongBytesFallsBackToOneConnection() async throws {
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 54)
        _ = try await downloadFallsBackToOneConnection(.init(data: data, misreportRangeStartBy: 1), name: "odd.bin")
    }

    /// On the probe's reply, the download falls back before asking for any segment. Only on
    /// segment replies, it falls back once the first one arrives.
    @Test(arguments: [true, false])
    func aContentEncodingOnARangeReplyFallsBackToOneConnection(onProbe: Bool) async throws {
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 55)
        let server = try await downloadFallsBackToOneConnection(
            .init(data: data, rangeReplyHeaders: ["Content-Encoding": "gzip"], rangeReplyHeadersOnProbe: onProbe),
            name: "packed.bin"
        )
        if onProbe { #expect(Self.ranges(asked: server) == ["bytes=0-0", nil]) }
    }

    /// The `Range` header of every request, in order, `nil` for a request without one.
    private static func ranges(asked server: TestServer) -> [String?] {
        server.requests.map { $0.headers["range"] }
    }

    /// Without a validator, a 200 to a segment request means the server ignored the range, not
    /// that the file changed.
    @Test func aServerThatIgnoresRangesFallsBackToOneConnection() async throws {
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 57)
        let server = try await downloadFallsBackToOneConnection(.init(data: data, ignoresSegmentRanges: true), name: "whole.bin")
        // The probe, the segment requests the server ignored, then one request for the whole file.
        #expect(server.requests.filter { $0.headers["range"] == nil }.count == 1)
    }

    /// The first segment writes some bytes, then the second segment's reply turns out wrong. After
    /// the fallback, the partial file describes one connection for the whole file with no
    /// validator, since it can't resume, and its data holds exactly the bytes the manifest counts,
    /// all of them the served file's own. The finished file is correct.
    @Test func thePartialFileStaysConsistentAfterAFallback() async throws {
        let server = try await TestServer()
        let size = 8 * 1024 * 1024
        let data = TestServer.makeData(size: size, seed: 58)
        server.serve(
            .init(
                data: data, holdAfterBytes: Self.held, misreportRangeStartBy: 1, eTag: "\"v1\"",
                misreportOnlyRangeStartingAt: size / 2
            ),
            at: "/mixed.iso"
        )
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.connections = 2

        let engine = DownloadEngine(configuration: .fastWithHolds)
        let id = await engine.add(url: server.url(for: "/mixed.iso"), to: folder, options: options)
        let package = folder.appending(path: "mixed.iso.dowlio")

        // The whole-file reply holds after `held` bytes; wait until the saved manifest shows it.
        try await waitUntil {
            guard let manifest = try? Self.manifest(in: package),
                  let segments = manifest["segments"] as? [[String: Any]], segments.count == 1 else { return false }
            return (segments[0]["received"] as? NSNumber)?.intValue == Self.held
        }
        #expect(server.requests.last?.headers["range"] == nil)

        let manifest = try Self.manifest(in: package)
        #expect(manifest["validator"] == nil || manifest["validator"] is NSNull)
        let segment = try #require((manifest["segments"] as? [[String: Any]])?.first)
        #expect((segment["start"] as? NSNumber)?.intValue == 0)
        #expect((segment["end"] as? NSNumber)?.intValue == size - 1)
        let written = try Data(contentsOf: package.appending(path: "data"))
        #expect(written == data.prefix(Self.held))

        server.releaseHeldResponses()
        let finished = try await engine.finished(id)
        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "mixed.iso")) == TestFiles.sha256(data))
    }

    private static func manifest(in package: URL) throws -> [String: Any] {
        let json = try Data(contentsOf: package.appending(path: "manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    @Test(arguments: [true, false])
    func aMultipartRangeReplyFallsBackToOneConnection(onProbe: Bool) async throws {
        let data = TestServer.makeData(size: 8 * 1024 * 1024, seed: 56)
        let server = try await downloadFallsBackToOneConnection(
            .init(
                data: data,
                rangeReplyHeaders: ["Content-Type": "multipart/byteranges; boundary=DOWLIO"],
                rangeReplyHeadersOnProbe: onProbe
            ),
            name: "parts.bin"
        )
        if onProbe { #expect(Self.ranges(asked: server) == ["bytes=0-0", nil]) }
    }
}
