import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ProtectedAndLiveTests {
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Streams/\(name)", withExtension: "m3u8")), encoding: .utf8)
    }

    @Test func anAES128PlaylistIsAVideoThatCanBeDownloaded() async throws {
        let site = try await Site()
        site.serve(html: "<title>Oceans</title>", at: "/watch")
        site.serve(text: try fixture("hls-media-aes128"), at: "/oceans/index.m3u8")

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/oceans/index.m3u8"), kind: .manifest)] }

        guard case .found(let candidates) = found, let video = candidates.first else { Issue.record("not found: \(found)"); return }
        #expect(video.restriction == nil)
        guard case .media(let media) = video.versions.first?.source else { Issue.record("not a stream"); return }
        #expect(media.tracks[0].fragments.allSatisfy { $0.key?.url == site.url("/oceans/oceans.key") })
    }

    @Test func aDRMPlaylistIsProtectedAndOffersNothingToDownload() async throws {
        let site = try await Site()
        site.serve(html: "<title>Film</title>", at: "/watch")
        site.serve(text: try fixture("hls-media-sample-aes"), at: "/drm/index.m3u8")

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/drm/index.m3u8"), kind: .manifest)] }

        #expect(found == .found([Candidate(label: "Film", duration: 20, versions: [], restriction: .protected)]))
        #expect(site.server.requests.allSatisfy { !$0.path.hasSuffix(".ts") })
    }

    @Test func aMasterWhoseVariantsUseADRMKeyFormatIsProtected() async throws {
        let site = try await Site()
        site.serve(html: "<title>Film</title>", at: "/watch")
        site.serve(text: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
            /drm/720.m3u8
            """, at: "/drm/master.m3u8")
        site.serve(text: """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,AAAA",KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
            #EXTINF:4,
            /drm/0.ts
            #EXT-X-ENDLIST
            """, at: "/drm/720.m3u8")

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/drm/master.m3u8"), kind: .manifest)] }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.restriction) == [.protected])
    }

    @Test func aPlaylistWithNoEndIsALiveStream() async throws {
        let site = try await Site()
        site.serve(html: "<title>Live now</title>", at: "/live")
        site.serve(text: try fixture("hls-media-live"), at: "/live/index.m3u8")

        let found = try await site.analyze("/live") { $0.watched = [WatchedRequest(url: site.url("/live/index.m3u8"), kind: .manifest)] }

        #expect(found == .found([Candidate(label: "Live now", duration: 18, versions: [], restriction: .live)]))
    }

    @Test func otherVideosOnThePageStayWhenOneIsProtected() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Mixed</title><video src="/media/trailer.mp4"></video>"#, at: "/watch")
        site.serve(video: 500, at: "/media/trailer.mp4")
        site.serve(text: try fixture("hls-media-sample-aes"), at: "/drm/index.m3u8")

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/drm/index.m3u8"), kind: .manifest)] }

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.restriction) == [nil, .protected])
        #expect(candidates.first?.versions.isEmpty == false)
    }
}
