import DowlioConnect
import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Network
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CatchTests {
    static func offer(_ url: URL, mime: String = "application/pdf", browserPath: String? = nil, requestId: String = "c1") -> [String: Any] {
        var offer: [String: Any] = [
            "v": 1, "type": "catch.offer", "requestId": requestId,
            "url": url.absoluteString, "finalUrl": url.absoluteString,
            "referrer": "https://example.com/reports", "mime": mime, "userAgent": "Mozilla/5.0 Test",
        ]
        if let browserPath { offer["browserPath"] = browserPath }
        return offer
    }

    @Test func anAcceptedCatchDownloadsInDowlioFollowingItsFolderRules() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 401)
        server.serve(.init(data: data, eTag: "\"c1\""), at: "/files/Report.pdf")
        let client = try await fixture.helloClient()
        let url = server.url(for: "/files/Report.pdf")

        try await client.send(Self.offer(url, browserPath: fixture.browserDownloads.appending(path: "Report.pdf").path))
        let reply = try await client.receive()
        let row = try await fixture.firstRow { $0.state == .completed }

        #expect(reply["type"] as? String == "catch.accepted")
        #expect(reply["requestId"] as? String == "c1")
        #expect(row.fileName == "Report.pdf")
        #expect(try TestFiles.sha256(of: fixture.dowlioFolder.appending(path: "Report.pdf")) == TestFiles.sha256(data))
        let probe = try #require(server.requests.first { $0.path == "/files/Report.pdf" })
        #expect(probe.headers["referer"] == "https://example.com/reports")
        #expect(probe.headers["user-agent"] == "Mozilla/5.0 Test")
    }

    @Test func aCatchUsesCategoryFoldersWhenDowlioSortsIntoThem() async throws {
        let fixture = try await ConnectFixture(settings: { folder in
            var settings = DownloadSettings(folder: folder)
            settings.sortsIntoCategoryFolders = true
            return settings
        })
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 402), eTag: "\"c2\""), at: "/Report.pdf")
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/Report.pdf")))
        _ = try await client.receive()
        _ = try await fixture.firstRow { $0.state == .completed }

        #expect(FileManager.default.fileExists(atPath: fixture.dowlioFolder.appending(path: "Documents/Report.pdf").path))
    }

    @Test func aFolderAndNameChosenInTheBrowsersSaveDialogAreKept() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 403), eTag: "\"c3\""), at: "/Report.pdf")
        let client = try await fixture.helloClient()
        let chosen = fixture.base.appending(path: "Taxes/2026", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        try await client.send(Self.offer(server.url(for: "/Report.pdf"), browserPath: chosen.appending(path: "Return.pdf").path))
        _ = try await client.receive()
        _ = try await fixture.firstRow { $0.state == .completed }

        #expect(FileManager.default.fileExists(atPath: chosen.appending(path: "Return.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.dowlioFolder.appending(path: "Report.pdf").path))
    }

    @Test func aSubfolderOfTheBrowsersDownloadsFolderChosenInTheSaveDialogIsKept() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 404), eTag: "\"c4\""), at: "/Report.pdf")
        let client = try await fixture.helloClient()
        let chosen = fixture.browserDownloads.appending(path: "Work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        try await client.send(Self.offer(server.url(for: "/Report.pdf"), browserPath: chosen.appending(path: "Report.pdf").path))
        _ = try await client.receive()
        _ = try await fixture.firstRow { $0.state == .completed }

        #expect(FileManager.default.fileExists(atPath: chosen.appending(path: "Report.pdf").path))
    }

    @Test(arguments: [401, 403])
    func aSiteThatWantsASignInIsDeclinedWithNeedsSignIn(status: Int) async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        var file = TestServer.File(data: Data(count: 1024))
        file.failFirst = .init(status: status)
        server.serve(file, at: "/private.zip")
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/private.zip"), mime: "application/zip"))
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "catch.declined")
        #expect(reply["reason"] as? String == "needsSignIn")
        #expect(await fixture.rowsNow().isEmpty)
    }

    @Test func aLinkThatNoLongerWorksIsDeclinedWithError() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        var file = TestServer.File(data: Data(count: 1024))
        file.failFirst = .init(status: 404)
        server.serve(file, at: "/gone.zip")
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/gone.zip"), mime: "application/zip"))
        let reply = try await client.receive()

        #expect(reply["reason"] as? String == "error")
        #expect(await fixture.rowsNow().isEmpty)
    }

    @Test func aWebPageWhereTheBrowserGotAFileIsDeclinedAsUnsupported() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        server.serve(.init(data: Data("<html>Sign in</html>".utf8), headers: ["Content-Type": "text/html; charset=utf-8"]), at: "/export")
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/export"), mime: "text/csv"))
        let reply = try await client.receive()

        #expect(reply["reason"] as? String == "unsupported")
        #expect(await fixture.rowsNow().isEmpty)
    }

    @Test func aCatchThatTakesTooLongToCheckIsDeclinedAndNeverStarts() async throws {
        let fixture = try await ConnectFixture(catchDeadline: .milliseconds(300))
        let silent = try await SilentServer()
        let client = try await fixture.helloClient()

        let sent = ContinuousClock.now
        try await client.send(Self.offer(silent.url, mime: "application/zip"))
        let reply = try await client.receive()
        let waited = ContinuousClock.now - sent
        try await Task.sleep(for: .milliseconds(300))

        #expect(waited < .seconds(1))
        #expect(reply["type"] as? String == "catch.declined")
        #expect(reply["reason"] as? String == "error")
        #expect(await fixture.rowsNow().isEmpty)
    }

    @Test func aCatchWaitsQueuedWhenDowlioIsRunningAsManyDownloadsAsAllowed() async throws {
        let fixture = try await ConnectFixture()
        await fixture.library.setMaximumActive(1)
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024 * 1024, seed: 404), holdAfterBytes: 0, eTag: "\"c4\""), at: "/big.iso")
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 405), eTag: "\"c5\""), at: "/small.zip")
        _ = await fixture.library.add(server.url(for: "/big.iso"), destination: .folder(fixture.dowlioFolder))
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/small.zip"), mime: "application/zip"))
        let reply = try await client.receive()
        let row = try await fixture.firstRow { $0.fileName == "small.zip" }

        #expect(reply["type"] as? String == "catch.accepted")
        #expect(row.state == .queued)
        server.releaseHeldResponses()
    }
}

final class SilentServer: @unchecked Sendable {
    private final class Held: @unchecked Sendable {
        var connections: [NWConnection] = []
    }

    private let listener: NWListener
    private let held = Held()
    let url: URL

    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = held
        let ready = AsyncStream<UInt16>.makeStream()
        listener.newConnectionHandler = { connection in
            held.connections.append(connection)
            connection.start(queue: .global())
        }
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await value in ready.stream {
            port = value
            break
        }
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)/slow.zip")!
    }

    deinit {
        listener.cancel()
    }
}
