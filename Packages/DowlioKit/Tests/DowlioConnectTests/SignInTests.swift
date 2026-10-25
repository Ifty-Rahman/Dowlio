import DowlioConnect
import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SignInTests {
    static var cookies: [[String: Any]] { [["name": "session", "value": "s3cr3t-4f9a"], ["name": "theme", "value": "dark"]] }

    @Test func aCatchCarryingTheSitesCookiesDownloadsAFileThatNeedsSignIn() async throws {
        let fixture = try await ConnectFixture()
        let server = try await TestServer()
        let data = TestServer.makeData(size: 256 * 1024, seed: 701)
        server.serve(.init(data: data, eTag: "\"p1\"", requiredCookie: "session=s3cr3t-4f9a"), at: "/private/Statement.pdf")
        let client = try await fixture.helloClient()
        var offer = CatchTests.offer(server.url(for: "/private/Statement.pdf"))
        offer["cookies"] = Self.cookies

        try await client.send(offer)
        let reply = try await client.receive()
        _ = try await fixture.firstRow { $0.state == .completed }

        #expect(reply["type"] as? String == "catch.accepted")
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == "session=s3cr3t-4f9a; theme=dark" })
        let database = try Data(contentsOf: fixture.base.appending(path: "Dowlio.sqlite"))
        #expect(database.range(of: Data("s3cr3t-4f9a".utf8)) == nil)
    }

    @Test func aSentLinkCarriesTheSitesCookiesToDowlio() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send([
            "v": 1, "type": "link.send", "requestId": "l1", "url": "https://example.com/private/a.pdf", "browser": "Arc", "cookies": Self.cookies,
        ])
        _ = try await client.receive()
        let sent = try await fixture.nextSentLink()

        #expect(sent.cookies == [Cookie(name: "session", value: "s3cr3t-4f9a"), Cookie(name: "theme", value: "dark")])
    }

    @Test func aCookieThatCouldBreakTheHeaderIsDroppedAndTheRestArrive() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()
        let cookies: [[String: String]] = [
            ["name": "a;b", "value": "1"], ["name": "a", "value": "1\r\nX-Evil: 1"], ["name": "", "value": "1"], ["value": "1"],
            ["name": "prefs", "value": "dark mode, large"],
        ]

        try await client.send(["v": 1, "type": "link.send", "requestId": "l1", "url": "https://example.com/a.pdf", "browser": "Arc", "cookies": cookies])
        _ = try await client.receive()
        let sent = try await fixture.nextSentLink()

        #expect(sent.cookies == [Cookie(name: "prefs", value: "dark mode, large")])
    }

    @Test func dowlioAsksTheBrowserThatSentALinkForItsSignIn() async throws {
        let fixture = try await ConnectFixture()
        let arc = try await fixture.helloClient()
        let brave = try await fixture.helloClient()
        try await arc.send(["v": 1, "type": "link.send", "requestId": "l1", "url": "https://example.com/private/a.pdf", "browser": "Arc"])
        _ = try await arc.receive()
        let sent = try await fixture.nextSentLink()

        #expect(await fixture.server.askForSignIn(sent))
        let asked = try await arc.receive()

        #expect(asked["type"] as? String == "signin.needed")
        #expect(asked["url"] as? String == "https://example.com/private/a.pdf")
        try await brave.send(["v": 1, "type": "ping", "requestId": "p1"])
        #expect(try await brave.receive()["type"] as? String == "pong")
    }

    @Test func aBrowsersAllowedSitesStayListedWhileItIsAway() async throws {
        let fixture = try await ConnectFixture()
        let arc = try await fixture.helloClient()
        try await arc.send(["v": 1, "type": "signin.sites", "requestId": "s1", "origins": ["https://example.com"]])
        _ = try await fixture.nextAllowedSites()
        arc.close()
        let brave = try await fixture.helloClient()

        try await brave.send(["v": 1, "type": "signin.sites", "requestId": "s2", "origins": ["https://other.org"]])

        #expect(try await fixture.nextAllowedSites() == [URL(string: "https://example.com")!, URL(string: "https://other.org")!])
    }

    @Test func allowingASiteSendsItsCookiesToDowlio() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send(["v": 1, "type": "signin.granted", "requestId": "g1", "origin": "https://example.com", "cookies": Self.cookies])
        let grant = try await fixture.nextSignInGrant()

        #expect(grant.origin == URL(string: "https://example.com"))
        #expect(grant.cookies.count == 2)
    }

    @Test func eachBrowsersAllowedSitesReachDowlioAndRemoveRevokesThemEverywhere() async throws {
        let fixture = try await ConnectFixture()
        let arc = try await fixture.helloClient()
        let brave = try await fixture.helloClient()

        try await arc.send(["v": 1, "type": "signin.sites", "requestId": "s1", "origins": ["https://example.com", "https://mail.example.org:8443", "ftp://files.example.net", 42]])
        let sites = try await fixture.nextAllowedSites()
        await fixture.server.revokeSignIn(URL(string: "https://example.com")!)

        #expect(sites == [URL(string: "https://example.com")!, URL(string: "https://mail.example.org")!])
        for client in [arc, brave] {
            let revoke = try await client.receive()
            #expect(revoke["type"] as? String == "signin.revoke")
            #expect(revoke["origin"] as? String == "https://example.com")
        }
    }
}
