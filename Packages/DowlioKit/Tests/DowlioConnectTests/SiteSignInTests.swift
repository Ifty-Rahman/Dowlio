import DowlioConnect
import DowlioCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SiteSignInTests {
    private let link = URL(string: "https://members.example.com/video/1")!

    @Test func theFrontBrowserIsAskedForTheLinkAndItsCookiesAndUserAgentComeBack() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        async let result = fixture.server.signIn(for: link, frontBrowser: "Arc")
        let request = try await client.receive()
        let requestID = try #require(request["requestId"] as? String)
        try await client.send([
            "v": 1, "type": "site.signIn", "requestId": requestID, "userAgent": "Mozilla/5.0 Arc",
            "cookies": [["name": "session", "value": "abc"], ["name": "hardened", "value": "xyz"]],
        ])

        #expect(request["type"] as? String == "site.signIn")
        #expect(request["url"] as? String == link.absoluteString)
        #expect(await result == SiteSignIn(cookies: [Cookie(name: "session", value: "abc"), Cookie(name: "hardened", value: "xyz")], userAgent: "Mozilla/5.0 Arc"))
    }

    @Test func withoutAConnectedBrowserNothingIsAsked() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })

        #expect(await fixture.server.signIn(for: link, frontBrowser: "Arc") == nil)
    }

    @Test func aBrowserThatIsNotInFrontIsNotAskedWhenAnotherSentSomethingLater() async throws {
        let name = Names(first: "Arc")
        let fixture = try await ConnectFixture(peerApp: { _ in name.current })
        let arc = try await fixture.helloClient()
        name.current = "Dia"
        let dia = try await fixture.helloClient()

        try await arc.send(["v": 1, "type": "link.send", "url": "https://example.com/a"])
        _ = try await arc.receive()
        async let second = fixture.server.signIn(for: link, frontBrowser: "Safari")
        let request = try await arc.receive()
        try await arc.send(["v": 1, "type": "site.signIn", "requestId": request["requestId"] as? String ?? "", "cookies": []])

        #expect(await second == SiteSignIn(cookies: []))
        await #expect(throws: ConnectClientError.timedOut) { try await dia.receive(timeout: .milliseconds(300)) }
    }

    @Test func whenNoBrowserHasSentAnythingTheLatestToConnectIsAsked() async throws {
        let name = Names(first: "Arc")
        let fixture = try await ConnectFixture(peerApp: { _ in name.current })
        let arc = try await fixture.helloClient()
        name.current = "Dia"
        let dia = try await fixture.helloClient()

        async let result = fixture.server.signIn(for: link, frontBrowser: nil)
        let request = try await dia.receive()
        try await dia.send(["v": 1, "type": "site.signIn", "requestId": request["requestId"] as? String ?? "", "cookies": []])

        #expect(await result == SiteSignIn(cookies: []))
        await #expect(throws: ConnectClientError.timedOut) { try await arc.receive(timeout: .milliseconds(300)) }
    }

    @Test func theFrontBrowserBeatsTheOneThatSentLast() async throws {
        let name = Names(first: "Arc")
        let fixture = try await ConnectFixture(peerApp: { _ in name.current })
        let arc = try await fixture.helloClient()
        name.current = "Dia"
        let dia = try await fixture.helloClient()
        try await arc.send(["v": 1, "type": "link.send", "url": "https://example.com/a"])
        _ = try await arc.receive()

        async let result = fixture.server.signIn(for: link, frontBrowser: "dia")
        let request = try await dia.receive()
        try await dia.send(["v": 1, "type": "site.signIn", "requestId": request["requestId"] as? String ?? "", "cookies": [["name": "a", "value": "b"]]])

        #expect(await result == SiteSignIn(cookies: [Cookie(name: "a", value: "b")]))
    }

    @Test func aBrowserThatNeverAnswersIsLeftAfterTheTimeout() async throws {
        let fixture = try await ConnectFixture(signInTimeout: .milliseconds(200), peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        async let result = fixture.server.signIn(for: link, frontBrowser: "Arc")
        _ = try await client.receive()

        #expect(await result == nil)
    }

    @Test func aBrowserThatHasntSaidHelloIsNotAsked() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        _ = try await fixture.pairedToken()
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "ping", "requestId": "p1"])
        _ = try await client.receive()

        #expect(await fixture.server.signIn(for: link, frontBrowser: "Arc") == nil)
    }

    @Test func aBrowserThatClosesWhileAskedGivesNothing() async throws {
        let fixture = try await ConnectFixture(peerApp: { _ in "Arc" })
        let client = try await fixture.helloClient()

        async let result = fixture.server.signIn(for: link, frontBrowser: "Arc")
        _ = try await client.receive()
        client.close()

        #expect(await result == nil)
    }

    @Test func anAnswerFromAnotherConnectionIsIgnored() async throws {
        let name = Names(first: "Arc")
        let fixture = try await ConnectFixture(signInTimeout: .milliseconds(400), peerApp: { _ in name.current })
        let arc = try await fixture.helloClient()
        name.current = "Dia"
        let dia = try await fixture.helloClient()

        async let result = fixture.server.signIn(for: link, frontBrowser: "Arc")
        let request = try await arc.receive()
        try await dia.send(["v": 1, "type": "site.signIn", "requestId": request["requestId"] as? String ?? "", "cookies": [["name": "x", "value": "y"]]])

        #expect(await result == nil)
    }
}
