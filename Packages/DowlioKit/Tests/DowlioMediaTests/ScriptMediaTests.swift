import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ScriptMediaTests {
    @Test func addressesInScriptAndDataAttributesAreFoundInEveryEscapedForm() async throws {
        let site = try await Site()
        let ads = try await Site()
        let server = String(site.url("/").absoluteString.dropLast())
        let escaped = server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? server
        let page = try PageFixture.html("script-escaped-addresses")
            .replacingOccurrences(of: "{{server}}", with: server)
            .replacingOccurrences(of: "{{escaped}}", with: escaped)
            .replacingOccurrences(of: "{{other}}", with: String(ads.url("/").absoluteString.dropLast()))
        site.serve(html: page, at: "/watch")
        for name in ["720", "480", "360"] { site.serve(video: 2_000_000 + Int(name)!, at: "/media/clip/\(name).mp4") }
        site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "part"), at: "/media/clip/index.m3u8")
        for index in 0..<2 { site.serve(video: 100_000, type: "video/mp2t", at: "/media/clip/part\(index).ts") }
        ads.serve(video: 300_000, at: "/ads/preroll.mp4")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let addresses = Set(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent))
        #expect(addresses == ["720.mp4", "480.mp4", "360.mp4", "part0.ts"])
    }

    @Test func shortPreviewsInScriptAreLeftOut() async throws {
        let site = try await Site()
        site.serve(html: """
            <title>Clip</title>
            <script>var related = [{"preview":"/previews/a.mp4"},{"preview":"/previews/b.mp4"}]; var main = {"video_url":"/media/main"};</script>
            """, at: "/watch")
        site.serve(video: 400_000, at: "/previews/a.mp4")
        site.serve(video: 500_000, at: "/previews/b.mp4")
        site.serve(video: 5_000_000, at: "/media/main")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["main"])
    }

    @Test func aSiteReadersPageIsLeftToItsReader() async throws {
        let site = try await ReaderSite { server in
            ScriptReader(video: SiteVideo(label: "Post", versions: [
                Version(source: .file(server.url(for: "/media/post.mp4")), contentType: "video/mp4", height: 720),
            ]))
        }
        site.site.serve(html: #"<title>Post</title><div data-sources="[{&quot;src&quot;:&quot;\/media\/post-360.mp4&quot;}]"></div>"#, at: "/post/1")
        site.site.serve(video: 2_000_000, at: "/media/post.mp4")
        site.site.serve(video: 1_000_000, at: "/media/post-360.mp4")

        let candidates = try await site.candidates("/post/1")

        #expect(candidates.flatMap(\.versions).map(\.source.url.lastPathComponent) == ["post.mp4"])
    }

    @Test func aPackedPlayerIsUnpackedWithoutRunningIt() async throws {
        let site = try await Site()
        site.serve(html: try PageFixture.html("script-packed-player"), at: "/watch")
        site.serve(text: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
            720p.m3u8
            """, at: "/stream/abc123/master.m3u8")
        site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "seg"), at: "/stream/abc123/720p.m3u8")
        for index in 0..<2 { site.serve(video: 100_000, type: "video/mp2t", at: "/stream/abc123/seg\(index).ts") }

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.label) == ["Sample clip - TUBE"])
        #expect(candidates.flatMap(\.versions).map(\.height) == [720])
    }
}

private struct ScriptReader: SiteReader {
    var video: SiteVideo
    var name: String { "Script" }
    func recognises(_ page: URL) -> Bool { page.path.hasPrefix("/post/") }
    func post(in page: URL) -> String? { nil }
    func read(_ page: SitePage) async throws -> [SiteVideo] { [video] }
}
