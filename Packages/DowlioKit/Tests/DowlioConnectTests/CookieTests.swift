import DowlioConnect
import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CookieTests {
    static var cookies: [[String: Any]] { [["name": "session", "value": "s3cr3t-4f9a"], ["name": "theme", "value": "dark"]] }

    @Test func aCatchCarryingTheSitesCookiesDownloadsAFileThatNeedsThem() async throws {
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

    @Test func theBrowserLearnsOnlyItsCatchingSettings() async throws {
        let fixture = try await ConnectFixture(preferences: CatchPreferences(catches: false, neverCatch: ["bank.example.com"]))
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await client.receive()
        let update = try await client.receive()

        #expect(update["type"] as? String == "settings.update")
        #expect(Set(update.keys) == ["v", "type", "catches", "neverCatch"])
        #expect(update["catches"] as? Bool == false)
        #expect(update["neverCatch"] as? [String] == ["bank.example.com"])
    }
}
