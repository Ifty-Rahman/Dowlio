import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CookieScopeTests {
    @Test func mediaOnAnotherHostIsAskedForWithoutThePagesCookies() async throws {
        let site = try await Site()
        let other = try await TestServer()
        other.serve(TestServer.File(data: Data(repeating: 7, count: 300), headers: ["Content-Type": "video/mp4"]), at: "/clip.mp4")
        let port = try #require(other.url(for: "/").port)
        let media = try #require(URL(string: "http://localhost:\(port)/clip.mp4"))
        site.serve(html: #"<video src="\#(media.absoluteString)"></video><video src="/own.mp4"></video>"#, at: "/watch")
        site.serve(video: 200, at: "/own.mp4")

        _ = try await site.analyze("/watch") { $0.cookies = [Cookie(name: "session", value: "abc")] }

        let elsewhere = other.requests.filter { $0.path == "/clip.mp4" }
        #expect(!elsewhere.isEmpty)
        #expect(elsewhere.allSatisfy { $0.headers["cookie"] == nil })
        #expect(site.server.requests.filter { $0.path == "/own.mp4" }.allSatisfy { $0.headers["cookie"] == "session=abc" })
    }

    @Test func aRedirectToAnotherHostDropsThePagesCookies() async throws {
        let site = try await Site()
        let other = try await TestServer()
        other.serve(TestServer.File(data: Data("#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"]), at: "/live.m3u8")
        let port = try #require(other.url(for: "/").port)
        let target = "http://localhost:\(port)/live.m3u8"
        site.server.redirect("/live.m3u8", to: target)
        site.serve(html: "<title>Stream</title><div id=player></div>", at: "/watch")

        _ = try await site.analyze("/watch") {
            $0.cookies = [Cookie(name: "session", value: "abc")]
            $0.watched = [WatchedRequest(url: site.url("/live.m3u8"), kind: .manifest)]
        }

        #expect(site.server.requests.contains { $0.path == "/live.m3u8" && $0.headers["cookie"] == "session=abc" })
        let followed = other.requests.filter { $0.path == "/live.m3u8" }
        #expect(!followed.isEmpty)
        #expect(followed.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test(arguments: [
        ("http://127.0.0.1:8080/a.mp4", true), ("http://localhost/a", true), ("http://printer.local/", true),
        ("http://192.168.1.1/", true), ("http://10.0.0.8/", true), ("http://172.20.1.1/", true), ("http://169.254.1.1/", true),
        ("http://[::1]/", true), ("http://[fd00::1]/", true), ("https://example.com/a.mp4", false), ("https://8.8.8.8/", false),
        ("http://172.32.0.1/", false),
    ])
    func localAddressesAreRecognised(_ address: String, _ local: Bool) throws {
        #expect(LocalAddress.isLocal(try #require(URL(string: address))) == local)
    }
}
