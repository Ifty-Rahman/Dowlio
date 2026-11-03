import DowlioCore
import Foundation
import Testing

struct CookieTests {
    private let page = URL(string: "https://www.example.com/watch")!

    @Test func aDomainCookieGoesToItsDomainAndSubdomainsOnly() {
        let cookie = Cookie(name: "sid", value: "1", domain: ".example.com")

        #expect(cookie.isSent(to: URL(string: "https://example.com/a")!, from: page))
        #expect(cookie.isSent(to: URL(string: "https://media.example.com/a")!, from: page))
        #expect(!cookie.isSent(to: URL(string: "https://notexample.com/a")!, from: page))
        #expect(!cookie.isSent(to: URL(string: "https://cdn.other.net/a")!, from: page))
    }

    @Test func aHostOnlyCookieGoesToItsHostOnly() {
        let cookie = Cookie(name: "sid", value: "1", domain: "www.example.com", hostOnly: true)

        #expect(cookie.isSent(to: URL(string: "https://www.example.com/a")!, from: page))
        #expect(!cookie.isSent(to: URL(string: "https://media.example.com/a")!, from: page))
    }

    @Test func aSecureCookieNeverGoesOverPlainHTTP() {
        let cookie = Cookie(name: "sid", value: "1", domain: ".example.com", secure: true)

        #expect(!cookie.isSent(to: URL(string: "http://www.example.com/a")!, from: page))
    }

    @Test func aCookieKeptForAPathStaysOnIt() {
        let cookie = Cookie(name: "sid", value: "1", domain: ".example.com", path: "/members")

        #expect(cookie.isSent(to: URL(string: "https://www.example.com/members/1")!, from: page))
        #expect(!cookie.isSent(to: URL(string: "https://www.example.com/public")!, from: page))
    }

    @Test func aCookieWithNoDomainGoesOnlyToThePagesOwnHost() {
        let cookie = Cookie(name: "sid", value: "1")

        #expect(cookie.isSent(to: URL(string: "https://www.example.com/video.mp4")!, from: page))
        #expect(!cookie.isSent(to: URL(string: "https://media.example.com/video.mp4")!, from: page))
    }
}
