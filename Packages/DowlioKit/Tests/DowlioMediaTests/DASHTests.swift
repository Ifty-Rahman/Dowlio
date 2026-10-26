import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DASHTests {
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/Streams/\(name)", withExtension: "mpd")), encoding: .utf8)
    }

    private func analyze(_ manifest: String, on site: Site) async throws -> PageAnalysis {
        site.serve(html: "<title>Big Buck Bunny</title>", at: "/watch")
        site.serve(text: manifest, type: "application/dash+xml", at: "/dash/stream.mpd")
        return try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/dash/stream.mpd"), kind: .manifest)] }
    }

    @Test func eachVideoRepresentationIsAVersionPairedWithTheBestAudio() async throws {
        let site = try await Site()

        let found = try await analyze(try fixture("dash-static"), on: site)

        guard case .found(let candidates) = found, let video = candidates.first, candidates.count == 1 else { Issue.record("not one video: \(found)"); return }
        #expect(video.label == "Big Buck Bunny")
        #expect(video.duration == 634.566)
        let videos = video.versions.filter { !$0.isAudio }
        #expect(videos.count == 10)
        #expect(Set(videos.compactMap(\.height)) == [180, 270, 360, 432, 576, 720, 1080, 2160])
        #expect(videos.first?.codecs == "H.264 + AAC")
        #expect(videos.first?.isEstimatedSize == true)
        guard case .media(let both) = videos.first?.source else { Issue.record("not media"); return }
        #expect(both.tracks.map(\.kind) == [.video, .audio])
        #expect(both.tracks[1].fragments.first?.url == site.url("/dash/bbb_a64k/bbb_a64k_1.m4a"))
        let audio = video.versions.filter(\.isAudio)
        #expect(audio.count == 1)
        #expect(audio.first?.isExtractedAudio == false)
    }

    @Test func onlyAudioAVFoundationCanMuxIsPairedAndListedOncePerLanguage() async throws {
        let site = try await Site()

        let found = try await analyze(try fixture("dash-static-languages-and-text"), on: site)

        guard case .found(let candidates) = found, let video = candidates.first else { Issue.record("not found: \(found)"); return }
        #expect(video.versions.filter { !$0.isAudio }.allSatisfy { $0.codecs?.contains("VP9") == false })
        let audio = video.versions.filter(\.isAudio)
        #expect(audio.compactMap(\.language).sorted() == ["de", "en", "es", "fr", "it"])
        #expect(audio.allSatisfy { $0.codecs == "AAC" })
    }

    @Test func aProtectedManifestIsProtected() async throws {
        let found = try await analyze(try fixture("dash-widevine"), on: try await Site())

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.restriction) == [.protected])
        #expect(candidates.first?.versions.isEmpty == true)
    }

    @Test func aDynamicManifestIsALiveStream() async throws {
        let found = try await analyze(try fixture("dash-dynamic"), on: try await Site())

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.restriction) == [.live])
    }

    @Test func aLinkStraightToAManifestIsAVideo() async throws {
        let site = try await Site()
        site.serve(text: try fixture("dash-static"), type: "application/dash+xml", at: "/dash/stream.mpd")

        let found = try await site.analyze("/dash/stream.mpd")

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.count == 1)
        #expect(candidates.first?.versions.count == 11)
    }
}
