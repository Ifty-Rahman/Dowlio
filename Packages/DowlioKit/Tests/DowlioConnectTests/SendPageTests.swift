import DowlioConnect
import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SendPageTests {
    @Test func aSentPageGetsAReceiptAndReachesDowlioWithWhatTheBrowserFound() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send([
            "v": 1, "type": "page.send", "requestId": "p1",
            "url": "https://example.com/watch?v=1", "title": "Holiday clip", "browser": "Arc",
            "userAgent": "Mozilla/5.0 Arc",
            "cookies": [["name": "session", "value": "abc"]],
            "media": [
                ["url": "https://cdn.example.com/clip.mp4", "kind": "video", "poster": "https://cdn.example.com/p.jpg", "duration": 61.5, "group": 1],
                ["url": "https://cdn.example.com/talk.m4a", "kind": "audio"],
            ],
            "embeddedJson": [#"{"video_versions":[]}"#],
            "requests": [
                ["url": "https://video.example.net/master.m3u8", "kind": "manifest", "contentType": "application/vnd.apple.mpegurl", "referrer": "https://example.com/watch?v=1"],
                ["url": "https://video.example.net/clip.mp4", "kind": "file", "contentType": "video/mp4"],
                ["url": "blob:https://example.com/1", "kind": "file"],
                ["url": "https://video.example.net/x.mp4", "kind": "segment"],
            ],
        ])
        let receipt = try await client.receive()
        let page = try await fixture.nextSentPage()

        #expect(receipt["type"] as? String == "page.received")
        #expect(receipt["requestId"] as? String == "p1")
        #expect(page == SentPage(
            url: URL(string: "https://example.com/watch?v=1")!,
            title: "Holiday clip",
            browser: "Arc",
            cookies: [Cookie(name: "session", value: "abc")],
            userAgent: "Mozilla/5.0 Arc",
            scan: [
                ScannedMedia(url: URL(string: "https://cdn.example.com/clip.mp4")!, kind: .video, poster: URL(string: "https://cdn.example.com/p.jpg"), duration: 61.5, group: 1),
                ScannedMedia(url: URL(string: "https://cdn.example.com/talk.m4a")!, kind: .audio),
            ],
            embeddedJSON: [#"{"video_versions":[]}"#],
            watched: [
                WatchedRequest(url: URL(string: "https://video.example.net/master.m3u8")!, kind: .manifest, contentType: "application/vnd.apple.mpegurl", referrer: URL(string: "https://example.com/watch?v=1")),
                WatchedRequest(url: URL(string: "https://video.example.net/clip.mp4")!, kind: .file, contentType: "video/mp4"),
            ]
        ))
    }

    @Test func scannedMediaThatIsntAWebLinkIsLeftOut() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send([
            "v": 1, "type": "page.send", "requestId": "p1", "url": "https://example.com/watch", "browser": "Arc",
            "media": [["url": "blob:https://example.com/1", "kind": "video"], ["url": "https://cdn.example.com/a.mp4", "kind": "video"]],
        ])
        _ = try await client.receive()

        #expect(try await fixture.nextSentPage().scan.map(\.url) == [URL(string: "https://cdn.example.com/a.mp4")!])
    }

    @Test func aSentPageThatIsntAWebPageIsRefused() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.helloClient()

        try await client.send(["v": 1, "type": "page.send", "requestId": "p1", "url": "file:///etc/hosts", "browser": "Arc"])
        let reply = try await client.receive()

        #expect(reply["type"] as? String == "error")
        #expect(reply["reason"] as? String == "invalidMessage")
    }

    @Test func aBrowserThatHasntSaidHelloCantSendPages() async throws {
        let fixture = try await ConnectFixture()
        let client = try await fixture.client()

        try await client.send(["v": 1, "type": "page.send", "requestId": "p1", "url": "https://example.com/watch", "browser": "Arc"])

        await #expect(throws: ConnectClientError.closed) { try await client.receive() }
    }
}
