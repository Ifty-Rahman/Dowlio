import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct OtherSitesTests {
    private func site(with standIn: YTDLPStandIn) async throws -> Site {
        let server = try await TestServer()
        let engine = DownloadEngine(configuration: .fast)
        let analyzer = PageAnalyzer(readers: [], ytdlp: YTDLPRunner(installer: standIn.installer)) { url, options in
            try await engine.inspect(url, options: options)
        }
        return Site(server: server, analyzer: analyzer)
    }

    private let emptyPage = "<html><head><title>A talk</title></head><body><p>Nothing to play here.</p></body></html>"

    @Test func aPageTheEarlierStepsCantReadIsTriedWithYTDLP() async throws {
        let standIn = try await YTDLPStandIn.printing("other-site.json")
        let site = try await site(with: standIn)
        site.serve(html: emptyPage, at: "/talks/creativity")

        let found = try await site.analyze("/talks/creativity")

        guard case .found(let candidates) = found, let talk = candidates.first else { Issue.record("not found: \(found)"); return }
        #expect(talk.label == "Do schools kill creativity?")
        #expect(!talk.versions.isEmpty)
        #expect(standIn.arguments.last == site.url("/talks/creativity").absoluteString)
    }

    @Test func aBilibiliLinkOnTheEnglishSiteIsGivenToYTDLPWithoutItsLanguage() async throws {
        let standIn = try await YTDLPStandIn.printing("other-site.json")
        let runner = YTDLPRunner(installer: standIn.installer)

        _ = try await runner.info(for: URL(string: "https://www.bilibili.com/en/video/BV1mmJt6kEYW/?spm_id_from=333.1007")!)

        #expect(standIn.arguments.last == "https://www.bilibili.com/video/BV1mmJt6kEYW/?spm_id_from=333.1007")
    }

    @Test func aPageTheEarlierStepsReadNeverRunsYTDLP() async throws {
        let standIn = try await YTDLPStandIn.printing("other-site.json")
        let site = try await site(with: standIn)
        site.serve(video: 4_000, at: "/media/clip.mp4")
        site.serve(html: "<html><body><video src=\"/media/clip.mp4\"></video></body></html>", at: "/watch")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.first?.versions.first?.source.url == site.url("/media/clip.mp4"))
        #expect(standIn.runs == 0)
    }

    @Test func aSiteYTDLPDoesntSupportStillEndsInNothingFound() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "unsupportedSite")
        let site = try await site(with: standIn)
        site.serve(html: emptyPage, at: "/blog")

        let found = try await site.analyze("/blog")

        #expect(found == .found([]))
        #expect(standIn.runs == 1)
    }

    @Test func aFailureOtherThanUnsupportedIsShown() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "geoBlocked")
        let site = try await site(with: standIn)
        site.serve(html: emptyPage, at: "/film")

        #expect(try await site.analyze("/film") == .ytdlpFailed(.geoBlocked))
    }

    @Test func withoutYTDLPInstalledAPageTheEarlierStepsCantReadEndsInNothingFound() async throws {
        let standIn = try await YTDLPStandIn.notInstalled()
        let site = try await site(with: standIn)
        site.serve(html: emptyPage, at: "/talks/creativity")

        #expect(try await site.analyze("/talks/creativity") == .found([]))
    }

    @Test func anEmbeddedYouTubePlayerBecomesACandidateThroughYTDLP() async throws {
        let standIn = try await YTDLPStandIn.printing("video-1080p.json")
        let site = try await site(with: standIn)
        site.serve(html: """
            <html><head><title>My favourite songs</title></head><body>
            <iframe width="560" height="315" src="https://www.youtube-nocookie.com/embed/2Vv-BfVoq4g" allowfullscreen></iframe>
            </body></html>
            """, at: "/blog/songs")

        let found = try await site.analyze("/blog/songs")

        guard case .found(let candidates) = found, let video = candidates.first else { Issue.record("not found: \(found)"); return }
        #expect(video.label == "Ed Sheeran - Perfect (Official Music Video)")
        #expect(video.versions.contains { $0.height == 1080 })
        #expect(standIn.arguments.last == "https://www.youtube-nocookie.com/embed/2Vv-BfVoq4g")
    }

    @Test func anEmbeddedYouTubePlayerWithoutTheToolsAsksForConsent() async throws {
        let standIn = try await YTDLPStandIn.notInstalled()
        let site = try await site(with: standIn)
        site.serve(html: """
            <html><body><iframe width="560" height="315" src="https://www.youtube.com/embed/2Vv-BfVoq4g"></iframe></body></html>
            """, at: "/blog/songs")

        #expect(try await site.analyze("/blog/songs") == .needsTools)
    }
}
