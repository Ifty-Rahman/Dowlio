import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PinterestReaderTests {
    private let pin = "/pin/100000000000000001/"

    private func pinterest() async throws -> ReaderSite {
        try await ReaderSite { _ in PinterestReader(hosts: ["127.0.0.1"]) }
    }

    @Test func aPinsVideoIsReadFromThePagesData() async throws {
        let site = try await pinterest()
        try site.serve(fixture: "pinterest-pin.html", at: pin)

        let candidates = try await site.candidates(pin)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample Maker: Paper stars to hang in the window")
        #expect(video.thumbnail == URL(string: "https://i.pinimg.example/videos/thumbnails/originals/00/11/22/sample0video0aaaa.0000000.jpg"))
        #expect(video.duration == 28.92)
        #expect(video.versions.map(\.source.url.lastPathComponent) == ["sample0video0aaaa_720w.mp4"])
        #expect(video.versions.map(\.height) == [606])
    }

    @Test func aPinWithOnlyAPlaylistIsReadThroughIt() async throws {
        let site = try await pinterest()
        site.site.serve(html: "<title>Pinterest</title>", at: pin)
        site.site.serve(text: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=662888,CODECS="avc1.64081F,mp4a.40.29",RESOLUTION=598x1066
            598/video.m3u8
            """, at: "/hls/pin.m3u8")
        site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "seg"), at: "/hls/598/video.m3u8")
        let only: [String: Any] = ["id": "100000000000000001", "title": "Stars", "videos": ["video_list": ["V_HLSV4": ["url": site.url("/hls/pin.m3u8").absoluteString, "width": 598, "height": 1066]]]]

        let candidates = try await site.candidates(pin) { $0.embeddedJSON = [PageFixture.json(only)] }

        #expect(candidates.first?.versions.compactMap(\.height) == [598])
    }

    @Test func aBoardListsEveryLoadedVideoPin() async throws {
        let site = try await pinterest()
        try site.serve(fixture: "pinterest-pin.html", at: "/sampleboard/")

        let candidates = try await site.candidates("/sampleboard/")

        #expect(Set(candidates.map(\.label)) == ["Sample Maker: Paper stars to hang in the window", "Other Maker: More like this"])
    }

    @Test func aShortLinkListsThePagesMainPin() async throws {
        let html = try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Readers/pinterest-pin", withExtension: "html")), encoding: .utf8)
        let start = try #require(html.range(of: #"type="application/json">"#)).upperBound
        let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        let page = SitePage(url: URL(string: "https://pin.it/AbCdEf1")!, embeddedJSON: [String(html[start..<end])]) { _ in Data() }

        let videos = try await PinterestReader().read(page)

        #expect(videos.map(\.label) == ["Sample Maker: Paper stars to hang in the window"])
    }

    @Test func aPinPageWithoutVideoIsLoggedAsFindingNothing() async throws {
        let site = try await pinterest()
        try site.serve(fixture: "pinterest-pin.html", at: "/pin/100000000000000009/")

        let found = try await site.site.analyze("/pin/100000000000000009/")

        #expect(found == .found([]))
        #expect(site.log.failures == [ReaderFailure(reader: "Pinterest", site: site.host, reason: "found nothing")])
    }

    @Test func pinterestRecognisesItsPermalinks() {
        let reader = PinterestReader()
        #expect(reader.recognises(URL(string: "https://www.pinterest.com/")!))
        #expect(reader.recognises(URL(string: "https://www.pinterest.co.uk/pin/424605071146207845/")!))
        #expect(reader.recognises(URL(string: "https://pin.it/AbCdEf1")!))
        #expect(!reader.recognises(URL(string: "https://notpinterest.com/pin/1/")!))
        #expect(reader.post(in: URL(string: "https://www.pinterest.com/pin/424605071146207845/")!) == "424605071146207845")
        #expect(reader.post(in: URL(string: "https://pin.it/AbCdEf1")!) == "AbCdEf1")
        #expect(reader.post(in: URL(string: "https://www.pinterest.com/pin/paper-stars--424605071146207845/")!) == "424605071146207845")
        #expect(reader.post(in: URL(string: "https://www.pinterest.com/someone/someboard/")!) == nil)
    }
}
