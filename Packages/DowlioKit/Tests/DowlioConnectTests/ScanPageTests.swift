import DowlioConnect
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ScanPageTests {
    @Test func askingABrowserToScanSendsItPageScanAndItsPageArrivesLikeASentPage() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        async let result = fixture.server.scanPage(in: "Arc")
        let request = try await client.receive()
        let requestID = try #require(request["requestId"] as? String)
        try await client.send(["v": 1, "type": "page.send", "requestId": requestID, "url": "https://example.com/watch?v=1", "title": "Holiday clip", "browser": "Arc"])
        let receipt = try await client.receive()

        #expect(request["type"] as? String == "page.scan")
        #expect(await result == .sent)
        #expect(receipt["type"] as? String == "page.received")
        #expect(receipt["requestId"] as? String == requestID)
        let page = try await fixture.nextSentPage()
        #expect(page.url == URL(string: "https://example.com/watch?v=1"))
        #expect(page.browser == "Arc")
    }

    @Test func onlyTheFrontBrowsersConnectionIsAsked() async throws {
        let name = Names(first: "Arc")
        let fixture = try await ConnectFixture(peerApp: { _ in name.current })
        let arc = try await fixture.helloClient()
        name.current = "Dia"
        let dia = try await fixture.helloClient()

        async let result = fixture.server.scanPage(in: "dia")
        let request = try await dia.receive()
        try await dia.send(["v": 1, "type": "page.send", "requestId": request["requestId"] as? String ?? "", "url": "https://example.com/a", "browser": "Dia"])

        #expect(await result == .sent)
        await #expect(throws: ConnectClientError.timedOut) { try await arc.receive(timeout: .milliseconds(300)) }
    }

    @Test func aBrowserWithoutAConnectionIsNotConnected() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        #expect(await fixture.server.scanPage(in: "Safari") == .notConnected)
        await #expect(throws: ConnectClientError.timedOut) { try await client.receive(timeout: .milliseconds(300)) }
    }

    @Test func aBrowserThatHasntSaidHelloIsNotAsked() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        _ = try await fixture.pairedToken()
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "ping", "requestId": "p1"])
        _ = try await client.receive()

        #expect(await fixture.server.scanPage(in: "Arc") == .notConnected)
    }

    @Test func aBrowserWithNoWebPageInFrontSaysSo() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        async let result = fixture.server.scanPage(in: "Arc")
        let request = try await client.receive()
        try await client.send(["v": 1, "type": "page.none", "requestId": request["requestId"] as? String ?? "", "reason": "noTab"])

        #expect(await result == .noPage)
    }

    @Test func aBrowserThatNeverAnswersGivesUpAfterTheDeadline() async throws {
        let fixture = try await ConnectFixture(scanTimeout: .milliseconds(200), peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        async let result = fixture.server.scanPage(in: "Arc")
        _ = try await client.receive()

        #expect(await result == .noAnswer)
    }

    @Test func aBrowserThatClosesWhileScanningIsNotConnected() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        async let result = fixture.server.scanPage(in: "Arc")
        _ = try await client.receive()
        client.close()

        #expect(await result == .notConnected)
    }
}
