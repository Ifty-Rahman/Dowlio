import DowlioConnect
import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DownloadInBrowserTests {
    @Test func downloadInBrowserInsteadThrowsAwayDowliosCopyAndHandsTheLinkBackToTheBrowser() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024 * 1024, seed: 406), holdAfterBytes: 64 * 1024, eTag: "\"d1\""), at: "/files/Big.iso")
        let client = try await fixture.helloClient()
        let url = server.url(for: "/files/Big.iso")
        try await client.send(CatchTests.offer(url, mime: "application/octet-stream"))
        _ = try await client.receive()
        let caught = try await fixture.nextCatch()
        _ = try await fixture.firstRow { $0.id == caught.id && $0.receivedBytes > 0 }

        let handedBack = await fixture.server.downloadInBrowser(caught)
        let message = try await client.receive()

        #expect(handedBack)
        #expect(message["type"] as? String == "browser.download")
        #expect(message["url"] as? String == url.absoluteString)
        #expect(await fixture.rowsNow().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.dowlioFolder.path).isEmpty)
        server.releaseHeldResponses()
    }

    @Test func aCatchNamesTheFileDowlioIsDownloading() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 407), eTag: "\"d2\""), at: "/files/Notes.pdf")
        server.redirect("/get", to: "/files/Notes.pdf")
        let client = try await fixture.helloClient()

        try await client.send(CatchTests.offer(server.url(for: "/get")))
        _ = try await client.receive()
        let caught = try await fixture.nextCatch()

        #expect(caught.fileName == "Notes.pdf")
        #expect(caught.totalBytes == Int64(64 * 1024))
    }

    @Test func dowlioKeepsTheDownloadWhenNoBrowserIsConnectedToTakeItBack() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024 * 1024, seed: 408), holdAfterBytes: 64 * 1024, eTag: "\"d3\""), at: "/files/Big.iso")
        let client = try await fixture.helloClient()
        try await client.send(CatchTests.offer(server.url(for: "/files/Big.iso"), mime: "application/octet-stream"))
        _ = try await client.receive()
        let caught = try await fixture.nextCatch()
        client.close()
        try await Task.sleep(for: .milliseconds(300))

        let handedBack = await fixture.server.downloadInBrowser(caught)

        #expect(!handedBack)
        #expect(await fixture.rowsNow().map(\.id) == [caught.id])
        server.releaseHeldResponses()
    }
}
