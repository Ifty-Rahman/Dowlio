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
}

@Suite(.timeLimit(.minutes(1)))
struct SignInSharingTests {
    private func catchOffer(_ server: TestServer, cookies: [[String: Any]]) -> [String: Any] {
        var offer = CatchTests.offer(server.url(for: "/private/Statement.pdf"))
        offer["cookies"] = cookies
        return offer
    }

    @Test func cookiesForASiteTheUserBlockedNeverReachTheDownload() async throws {
        let fixture = try await ConnectFixture(preferences: CatchPreferences(noSignIn: ["127.0.0.1"]))
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024, seed: 702), eTag: "\"p2\"", requiredCookie: "session=s3cr3t-4f9a"), at: "/private/Statement.pdf")
        let client = try await fixture.helloClient()

        try await client.send(catchOffer(server, cookies: SignInTests.cookies))
        _ = try await client.receive()
        let handBack = try await client.receive()

        #expect(handBack["type"] as? String == "browser.download")
        #expect(handBack["reason"] as? String == "needsSignIn")
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test func turningSignInSharingOffDropsEveryonesCookies() async throws {
        let fixture = try await ConnectFixture(preferences: CatchPreferences(sharesSignIn: false))
        let client = try await fixture.helloClient()

        try await client.send([
            "v": 1, "type": "link.send", "requestId": "l1", "url": "https://example.com/a.pdf", "browser": "Arc", "cookies": SignInTests.cookies,
        ])
        _ = try await client.receive()

        #expect(try await fixture.nextSentLink().cookies.isEmpty)
    }

    @Test func eachUseOfASitesCookiesIsReportedSoTheAppCanListIt() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send([
            "v": 1, "type": "link.send", "requestId": "l1", "url": "https://files.example.com/a.pdf", "browser": "Arc", "cookies": SignInTests.cookies,
        ])
        _ = try await client.receive()

        #expect(try await fixture.nextSignInUse() == "files.example.com")
    }

    @Test func aLinkSentWithNoCookiesIsNotReportedAsUsingSignIn() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()
        try await client.send(["v": 1, "type": "link.send", "requestId": "l1", "url": "https://files.example.com/a.pdf", "browser": "Arc"])
        _ = try await client.receive()
        try await client.send([
            "v": 1, "type": "link.send", "requestId": "l2", "url": "https://other.example.org/a.pdf", "browser": "Arc", "cookies": SignInTests.cookies,
        ])
        _ = try await client.receive()

        #expect(try await fixture.nextSignInUse() == "other.example.org")
    }

    @Test func theBrowserLearnsTheSignInSwitchAndBlockedSitesWithItsOtherSettings() async throws {
        let fixture = try await ConnectFixture(preferences: CatchPreferences(sharesSignIn: false, noSignIn: ["bank.example.com"]))
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await client.receive()
        let update = try await client.receive()

        #expect(update["signIn"] as? Bool == false)
        #expect(update["noSignIn"] as? [String] == ["bank.example.com"])
    }
}

struct SignInPreferenceTests {
    @Test func signInIsSharedByDefaultWithEverySite() {
        let preferences = CatchPreferences()
        #expect(preferences.sharesSignIn)
        #expect(preferences.allowsSignIn(for: "files.example.com"))
    }

    @Test func aBlockedSiteAndItsSubdomainsGetNoSignInButSimilarNamesDo() {
        var preferences = CatchPreferences()
        preferences.noSignInOn("WWW.Example.com")

        #expect(!preferences.allowsSignIn(for: "example.com"))
        #expect(!preferences.allowsSignIn(for: "files.example.com"))
        #expect(preferences.allowsSignIn(for: "badexample.com"))
        #expect(preferences.noSignIn == ["example.com"])
    }

    @Test func switchingSharingOffBlocksEverySite() {
        var preferences = CatchPreferences()
        preferences.sharesSignIn = false
        #expect(!preferences.allowsSignIn(for: "example.com"))
    }

    @Test func unblockingASiteSharesItsSignInAgain() {
        var preferences = CatchPreferences(noSignIn: ["a.com", "b.com"])
        preferences.signInAgain("a.com")
        #expect(preferences.noSignIn == ["b.com"])
    }

    @Test func theBlockedListHasALimitAndRefusesNonsense() {
        var preferences = CatchPreferences()
        preferences.noSignInOn("not a site")
        for index in 0...CatchPreferences.maximumSites { preferences.noSignInOn("site\(index).com") }
        #expect(preferences.noSignIn.count == CatchPreferences.maximumSites)
    }
}

struct SignInLogTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eachUseCountsAndTheMostRecentSiteComesFirst() {
        var log = SignInLog()
        log.record("a.com", at: start)
        log.record("b.com", at: start.addingTimeInterval(10))
        log.record("a.com", at: start.addingTimeInterval(20))

        #expect(log.sites.map(\.host) == ["a.com", "b.com"])
        #expect(log.sites.first?.uses == 2)
        #expect(log.sites.first?.lastUsed == start.addingTimeInterval(20))
    }

    @Test func removingASiteForgetsItUntilItIsUsedAgain() {
        var log = SignInLog()
        log.record("a.com", at: start)
        log.remove("a.com")
        #expect(log.sites.isEmpty)
        log.record("a.com", at: start)
        #expect(log.sites.first?.uses == 1)
    }

    @Test func theLogKeepsOnlyTheMostRecentSitesAndSurvivesSaving() throws {
        var log = SignInLog()
        for index in 0...SignInLog.maximumSites { log.record("site\(index).com", at: start.addingTimeInterval(Double(index))) }

        let restored = try JSONDecoder().decode(SignInLog.self, from: JSONEncoder().encode(log))

        #expect(restored.sites.count == SignInLog.maximumSites)
        #expect(restored == log)
        #expect(!restored.sites.contains { $0.host == "site0.com" })
    }

    @Test func theLogHoldsNoCookieValues() throws {
        var log = SignInLog()
        log.record("a.com", at: start)
        let text = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
        #expect(!text.contains("cookie"))
    }
}
