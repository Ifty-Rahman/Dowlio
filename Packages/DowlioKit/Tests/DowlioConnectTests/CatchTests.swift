import DowlioConnect
import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Network
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CatchTests {
    static func offer(_ url: URL, mime: String = "application/pdf", requestId: String = "c1") -> [String: Any] {
        var offer: [String: Any] = [
            "v": 1, "type": "catch.offer", "requestId": requestId,
            "url": url.absoluteString, "finalUrl": url.absoluteString,
            "referrer": "https://example.com/reports", "mime": mime, "userAgent": "Mozilla/5.0 Test",
        ]
        return offer
    }

    @Test func anAcceptedCatchDownloadsInDowlioFollowingItsFolderRules() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 2 * 1024 * 1024, seed: 401)
        server.serve(.init(data: data, eTag: "\"c1\""), at: "/files/Report.pdf")
        let client = try await fixture.helloClient()
        let url = server.url(for: "/files/Report.pdf")

        try await client.send(Self.offer(url))
        let reply = try await client.receive()
        let row = try await fixture.firstRow { $0.state == .completed }

        #expect(reply["type"] as? String == "catch.accepted")
        #expect(reply["requestId"] as? String == "c1")
        #expect(row.fileName == "Report.pdf")
        #expect(row.origin == DownloadOrigin(kind: .caught, browser: "Arc"))
        #expect(try TestFiles.sha256(of: fixture.dowlioFolder.appending(path: "Report.pdf")) == TestFiles.sha256(data))
        let probe = try #require(server.requests.first { $0.path == "/files/Report.pdf" })
        #expect(probe.headers["referer"] == "https://example.com/reports")
        #expect(probe.headers["user-agent"] == "Mozilla/5.0 Test")
    }

    @Test func aFileTheBrowserGotByPostingAFormIsCaughtWithThatFormAndItsHeaders() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        let form = Data("op=download2&id=bazoiwepu9vx".utf8)
        let data = TestServer.makeData(size: 512 * 1024, seed: 409)
        server.serve(.init(data: data, eTag: "\"c9\"", headers: ["Content-Disposition": "attachment; filename=\"Archive.tar.gz\""], requiredForm: form), at: "/bazoiwepu9vx")
        let client = try await fixture.helloClient()
        var offer = Self.offer(server.url(for: "/bazoiwepu9vx"), mime: "application/gzip")
        offer["request"] = [
            "method": "POST",
            "body": form.base64EncodedString(),
            "headers": [
                ["name": "Content-Type", "value": "application/x-www-form-urlencoded"],
                ["name": "Origin", "value": "https://send.now"],
                ["name": "X-Requested-With", "value": "XMLHttpRequest"],
                ["name": "Host", "value": "evil.example"],
                ["name": "Cookie", "value": "smuggled=1"],
                ["name": "Bad Name", "value": "x"],
            ],
        ]

        try await client.send(offer)
        let reply = try await client.receive()
        let row = try await fixture.firstRow { $0.state == .completed }

        #expect(reply["type"] as? String == "catch.accepted")
        #expect(row.fileName == "Archive.tar.gz")
        #expect(try TestFiles.sha256(of: fixture.dowlioFolder.appending(path: "Archive.tar.gz")) == TestFiles.sha256(data))
        let requests = server.requests.filter { $0.path == "/bazoiwepu9vx" }
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.method == "POST" && $0.body == form })
        #expect(requests.allSatisfy { $0.headers["origin"] == "https://send.now" && $0.headers["x-requested-with"] == "XMLHttpRequest" })
        #expect(requests.allSatisfy { $0.headers["content-type"] == "application/x-www-form-urlencoded" })
        #expect(requests.allSatisfy { $0.headers["host"]?.hasPrefix("127.0.0.1") == true && $0.headers["cookie"] == nil })
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

    @Test func aCatchIsAcceptedBeforeDowlioAsksTheHostForAnything() async throws {
        let fixture = try await ConnectFixture()
        let silent = try await SilentServer()
        let client = try await fixture.helloClient()

        let sent = ContinuousClock.now
        try await client.send(Self.offer(silent.url, mime: "application/zip"))
        let reply = try await client.receive()

        #expect(ContinuousClock.now - sent < .seconds(1))
        #expect(reply["type"] as? String == "catch.accepted")
        _ = try await fixture.firstRow { $0.sourceURL == silent.url }
    }

    @Test func dowlioAsksTheHostOnlyOnceTheBrowserHasLetGoOfTheDownload() async throws {
        let fixture = try await ConnectFixture(releaseWait: .seconds(10))
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 412), eTag: "\"c12\""), at: "/d/CleanMyMac.tar.gz")
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/d/CleanMyMac.tar.gz"), mime: "application/gzip"))
        let reply = try await client.receive()
        try await Task.sleep(for: .milliseconds(300))
        let askedBeforeRelease = server.requests.count
        try await client.send(["v": 1, "type": "catch.released", "requestId": "c1"])
        let row = try await fixture.firstRow { $0.state == .completed }

        #expect(reply["type"] as? String == "catch.accepted")
        #expect(askedBeforeRelease == 0)
        #expect(row.fileName == "CleanMyMac.tar.gz")
    }

    @Test func withoutWordThatTheBrowserLetGoDowlioStartsAfterAShortWait() async throws {
        let fixture = try await ConnectFixture(releaseWait: .milliseconds(200))
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 413), eTag: "\"c13\""), at: "/Report.pdf")
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/Report.pdf")))
        _ = try await client.receive()
        let row = try await fixture.firstRow { $0.state == .completed }

        #expect(row.fileName == "Report.pdf")
    }

    @Test(arguments: [(401, "needsSignIn"), (403, "needsSignIn"), (404, "error")])
    func aCatchTheHostRefusesGoesBackToTheBrowser(status: Int, reason: String) async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        var file = TestServer.File(data: Data(count: 1024))
        file.failFirst = .init(status: status)
        server.serve(file, at: "/private.zip")
        let client = try await fixture.helloClient()
        let url = server.url(for: "/private.zip")

        try await client.send(Self.offer(url, mime: "application/zip"))
        let reply = try await client.receive()
        let handBack = try await client.receive()
        try await Task.sleep(for: .milliseconds(100))

        #expect(reply["type"] as? String == "catch.accepted")
        #expect(handBack["type"] as? String == "browser.download")
        #expect(handBack["url"] as? String == url.absoluteString)
        #expect(handBack["reason"] as? String == reason)
        #expect(await fixture.rowsNow().isEmpty)
    }

    @Test func aCatchTheHostRefusesStaysInDowlioAndIsAnnouncedWhenNoBrowserCanTakeItBack() async throws {
        let fixture = try await ConnectFixture(releaseWait: .milliseconds(300))
        let server = try await TestServer()
        var file = TestServer.File(data: Data(count: 1024))
        file.failFirst = .init(status: 403)
        server.serve(file, at: "/private.zip")
        let client = try await fixture.helloClient()
        let url = server.url(for: "/private.zip")

        try await client.send(Self.offer(url, mime: "application/zip"))
        _ = try await client.receive()
        client.close()
        let announced = try await fixture.nextCatch()
        let row = try await fixture.firstRow { $0.id == announced.id }

        #expect(announced.link == url)
        #expect(row.state == .failed(.forbidden))
    }

    @Test func aCatchTheHostRefusesIsNeverAnnounced() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        var refused = TestServer.File(data: Data(count: 1024))
        refused.failFirst = .init(status: 403)
        server.serve(refused, at: "/private.zip")
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 411), eTag: "\"c11\""), at: "/Public.pdf")
        let client = try await fixture.helloClient()

        try await client.send(Self.offer(server.url(for: "/private.zip"), mime: "application/zip", requestId: "c1"))
        _ = try await client.receive()
        _ = try await client.receive()
        try await client.send(Self.offer(server.url(for: "/Public.pdf"), requestId: "c2"))
        let announced = try await fixture.nextCatch()

        #expect(announced.fileName == "Public.pdf")
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
