import DowlioConnect
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SendLinkTests {
    @Test func aSentLinkGetsAReceiptAndReachesDowlioWithItsPageAndBrowser() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send([
            "v": 1, "type": "link.send", "requestId": "l1",
            "url": "https://cdn.example.com/files/Report.pdf", "referrer": "https://example.com/reports", "browser": "Arc",
            "userAgent": "Mozilla/5.0 Arc",
        ])
        let receipt = try await client.receive()
        let sent = try await fixture.nextSentLink()

        #expect(receipt["type"] as? String == "link.received")
        #expect(receipt["requestId"] as? String == "l1")
        #expect(sent.url == URL(string: "https://cdn.example.com/files/Report.pdf"))
        #expect(sent.referrer == URL(string: "https://example.com/reports"))
        #expect(sent.browser == "Arc")
        #expect(sent.userAgent == "Mozilla/5.0 Arc")
        #expect(sent.cookies.isEmpty)
    }

    @Test func aSentLinkThatIsntAWebLinkIsRefused() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send(["v": 1, "type": "link.send", "requestId": "l1", "url": "file:///etc/hosts", "browser": "Arc"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "error")
        #expect(reply["reason"] as? String == "invalidMessage")
    }

    @Test func aBrowserThatHasntSaidHelloCantSendLinks() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "link.send", "requestId": "l1", "url": "https://example.com/a.zip", "browser": "Arc"])

        await #expect(throws: ConnectClientError.closed) { try await client.receive() }
    }
}
