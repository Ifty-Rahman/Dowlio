import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PlayerFrameTests {
    @Test func theOnlyPlayerFrameOnAPageWithNoVideoIsReadWithThePageAsReferrer() async throws {
        let site = try await Site()
        site.serve(html: """
            <title>How to tie a knot</title>
            <iframe src="https://securepubads.g.doubleclick.net/ad/frame.html" width="300" height="250"></iframe>
            <iframe src="/embed/1" width="640" height="360"></iframe>
            <iframe src="/badge" width="88" height="31"></iframe>
            """, at: "/blog/knots")
        site.serve(html: #"<video src="/media/knot.mp4"></video><iframe src="/nested"></iframe>"#, at: "/embed/1")
        site.serve(html: #"<video src="/media/nested.mp4"></video>"#, at: "/nested")
        site.serve(video: 2_000_000, at: "/media/knot.mp4")
        site.serve(video: 2_000_000, at: "/media/nested.mp4")

        let found = try await site.analyze("/blog/knots")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["How to tie a knot"])
        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["knot.mp4"])
        let frame = site.server.requests.filter { $0.path == "/embed/1" }
        #expect(frame.first?.headers["referer"] == site.url("/blog/knots").absoluteString)
        #expect(!site.server.requests.contains { $0.path == "/nested" || $0.path == "/badge" })
    }

    @Test func aFrameOnAPageThatHasItsOwnVideoIsNotRead() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Page</title><video src="/media/own.mp4"></video><iframe src="/embed/2"></iframe>"#, at: "/watch")
        site.serve(html: #"<video src="/media/framed.mp4"></video>"#, at: "/embed/2")
        site.serve(video: 2_000_000, at: "/media/own.mp4")
        site.serve(video: 2_000_000, at: "/media/framed.mp4")

        _ = try await site.analyze("/watch")

        #expect(!site.server.requests.contains { $0.path == "/embed/2" })
    }

    @Test func framesAReaderRecognisesAreReadUpToThreeInPageOrder() async throws {
        let site = try await ReaderSite { server in FramedPlayerReader(server: server) }
        let frames = (1...5).map { #"<iframe src="/player/\#($0)"></iframe>"# }.joined()
        site.site.serve(html: #"<title>Course</title><video src="/media/intro.mp4"></video>\#(frames)"#, at: "/course")
        site.site.serve(video: 2_000_000, at: "/media/intro.mp4")
        for index in 1...5 {
            site.site.serve(html: "<title>Lesson \(index)</title>", at: "/player/\(index)")
            site.site.serve(video: 3_000_000 + index, at: "/media/lesson\(index).mp4")
        }

        let candidates = try await site.candidates("/course")

        let files = Set(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent))
        #expect(files == ["intro.mp4", "lesson1.mp4", "lesson2.mp4", "lesson3.mp4"])
    }
}

private struct FramedPlayerReader: SiteReader {
    let server: TestServer
    var name: String { "Framed player" }
    func recognises(_ page: URL) -> Bool { page.path.hasPrefix("/player/") }
    func post(in page: URL) -> String? { page.lastPathComponent }
    func read(_ page: SitePage) async throws -> [SiteVideo] {
        [SiteVideo(label: "Lesson \(page.url.lastPathComponent)", duration: Double(page.url.lastPathComponent) ?? 0, versions: [
            Version(source: .file(server.url(for: "/media/lesson\(page.url.lastPathComponent).mp4")), contentType: "video/mp4"),
        ])]
    }
}
