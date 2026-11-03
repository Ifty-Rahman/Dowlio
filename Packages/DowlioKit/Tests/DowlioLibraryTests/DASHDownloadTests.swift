import AVFoundation
import DowlioCore
import DowlioEngine
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DASHDownloadTests {
    @Test func aDASHVideoWithSeparateTracksBecomesOnePlayableFile() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        for name in ["video-init.mp4", "video0.m4s", "video1.m4s", "video2.m4s", "audio-init.mp4", "audio0.m4s", "audio1.m4s", "audio2.m4s"] {
            server.serve(TestServer.File(data: try TestMedia.data(name)), at: "/dash/\(name)")
        }
        server.serve(TestServer.File(data: Data("""
            <MPD type="static" mediaPresentationDuration="PT3S">
              <Period>
                <AdaptationSet mimeType="video/mp4">
                  <SegmentTemplate timescale="1" duration="1" startNumber="0" initialization="$RepresentationID$-init.mp4" media="$RepresentationID$$Number$.m4s"/>
                  <Representation id="video" bandwidth="300000" height="360" codecs="avc1.64001e"/>
                </AdaptationSet>
                <AdaptationSet mimeType="audio/mp4">
                  <SegmentTemplate timescale="1" duration="1" startNumber="0" initialization="$RepresentationID$-init.mp4" media="$RepresentationID$$Number$.m4s"/>
                  <Representation id="audio" bandwidth="64000" codecs="mp4a.40.2"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """.utf8), headers: ["Content-Type": "application/dash+xml"]), at: "/dash/stream.mpd")
        let engine = DownloadEngine(configuration: .fast)
        var last: PageAnalysis?
        for await update in PageAnalyzer(inspect: { url, options in try await engine.inspect(url, options: options) })
            .analyze(SentPage(url: server.url(for: "/dash/stream.mpd"))) { last = update }
        guard case .found(let candidates) = last, let version = candidates.first?.versions.first(where: { !$0.isAudio }) else {
            Issue.record("no video: \(String(describing: last))"); return
        }
        var options = RequestOptions()
        options.fileName = "Bunny.mp4"

        let id = await fixture.library.add(version.source, destination: .folder(fixture.folder), options: options)
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        let asset = AVURLAsset(url: fixture.folder.appending(path: "Bunny.mp4"))
        #expect(Set(try await asset.load(.tracks).map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }
}
