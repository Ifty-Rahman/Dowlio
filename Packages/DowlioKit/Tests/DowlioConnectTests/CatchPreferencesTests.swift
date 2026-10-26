import DowlioConnect
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CatchPreferencesTests {
    @Test func aBrowserLearnsTheCatchSwitchAndNeverCatchListRightAfterHello() async throws {
        let fixture = try await ConnectFixture(preferences: CatchPreferences(catches: false, neverCatch: ["example.com"]))
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        let hello = try await client.receive()
        let update = try await client.receive()

        #expect(hello["type"] as? String == "hello.ok")
        #expect(update["type"] as? String == "settings.update")
        #expect(update["catches"] as? Bool == false)
        #expect(update["neverCatch"] as? [String] == ["example.com"])
    }

    @Test func aChangeInDowlioReachesEveryConnectedBrowser() async throws {
        let fixture = try await ConnectFixture()
        let arc = try await fixture.helloClient()
        let brave = try await fixture.helloClient()

        await fixture.server.publish(CatchPreferences(catches: false, neverCatch: []))

        for client in [arc, brave] {
            let update = try await client.receive()
            #expect(update["type"] as? String == "settings.update")
            #expect(update["catches"] as? Bool == false)
        }
    }

    @Test func aChangeFromAPopupGoesToDowlioWhichSendsTheResultToEveryBrowser() async throws {
        let fixture = try await ConnectFixture()
        let arc = try await fixture.helloClient()
        let brave = try await fixture.helloClient()

        try await arc.send(["v": 1, "type": "settings.change", "requestId": "s1", "neverCatchSite": "WWW.Example.com"])
        let change = try await fixture.nextPreferenceChange()
        let saved = change.applied(to: CatchPreferences())
        await fixture.server.publish(saved)

        #expect(saved == CatchPreferences(catches: true, neverCatch: ["example.com"]))
        for client in [arc, brave] {
            let update = try await client.receive()
            #expect(update["neverCatch"] as? [String] == ["example.com"])
        }
    }

    @Test func turningCatchingOffFromAPopupKeepsTheNeverCatchList() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send(["v": 1, "type": "settings.change", "requestId": "s1", "catches": false])
        let change = try await fixture.nextPreferenceChange()

        #expect(change.applied(to: CatchPreferences(catches: true, neverCatch: ["mega.nz"])) == CatchPreferences(catches: false, neverCatch: ["mega.nz"]))
    }

    @Test func aBrowserThatHasntSaidHelloCantChangeSettings() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "settings.change", "requestId": "s1", "catches": false])

        await #expect(throws: ConnectClientError.closed) { try await client.receive() }
    }

    @Test(arguments: ["", "not a site", "https://example.com/page", "a..b", ".example.com", String(repeating: "a", count: 300) + ".com"])
    func aSiteThatIsntAHostNameIsIgnored(site: String) {
        var preferences = CatchPreferences()
        preferences.neverCatchOn(site)
        #expect(preferences.neverCatch.isEmpty)
    }

    @Test func aSiteWithoutADotSuchAsLocalhostCanBeListed() {
        var preferences = CatchPreferences()
        preferences.neverCatchOn("LocalHost")
        #expect(preferences.neverCatch == ["localhost"])
    }

    @Test func theListStopsGrowingAtItsLimit() {
        var preferences = CatchPreferences()
        for index in 0...CatchPreferences.maximumSites { preferences.neverCatchOn("site\(index).com") }
        #expect(preferences.neverCatch.count == CatchPreferences.maximumSites)
    }

    @Test func removingASiteCatchesItsDownloadsAgain() {
        var preferences = CatchPreferences(catches: true, neverCatch: ["a.com", "b.com"])
        preferences.catchAgain("a.com")
        #expect(preferences.neverCatch == ["b.com"])
    }
}
