import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SizeTests {
    @Test func aFileWithAnEstimatedSizeIsAskedForItsSize() async throws {
        let site = try await ReaderSite { server in
            FixedReader(video: SiteVideo(label: "Post", duration: 10, versions: [
                Version(source: .file(server.url(for: "/v/720.mp4")), contentType: "video/mp4", totalBytes: 5000, isEstimatedSize: true, height: 720),
            ]))
        }
        site.site.serve(html: "<title>Post</title>", at: "/post/1")
        site.site.serve(video: 7321, at: "/v/720.mp4")

        let versions = try await site.candidates("/post/1").first?.versions ?? []

        #expect(versions.map(\.totalBytes) == [7321])
        #expect(versions.map(\.isEstimatedSize) == [false])
    }

    @Test func aSizeCheckThatFailsKeepsTheEstimateAndTheRow() async throws {
        let site = try await ReaderSite { server in
            FixedReader(video: SiteVideo(label: "Post", duration: 10, versions: [
                Version(source: .file(server.url(for: "/v/gone.mp4")), contentType: "video/mp4", totalBytes: 5000, isEstimatedSize: true, height: 720),
            ]))
        }
        site.site.serve(html: "<title>Post</title>", at: "/post/1")

        let versions = try await site.candidates("/post/1").first?.versions ?? []

        #expect(versions.map(\.totalBytes) == [5000])
        #expect(versions.map(\.isEstimatedSize) == [true])
    }

    @Test func aDASHVideoOfOneFilePairedWithAudioShowsBothSizesAddedTogether() async throws {
        let site = try await Site()
        site.serve(html: "<title>Reel</title>", at: "/watch")
        site.serve(text: """
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S">
              <Period>
                <AdaptationSet mimeType="video/mp4">
                  <Representation id="v1" bandwidth="800000" codecs="avc1.64001f" width="1280" height="720"><BaseURL>video-720.mp4</BaseURL><SegmentBase indexRange="0-100"/></Representation>
                </AdaptationSet>
                <AdaptationSet mimeType="audio/mp4">
                  <Representation id="a1" bandwidth="64000" codecs="mp4a.40.2"><BaseURL>audio.m4a</BaseURL></Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """, type: "application/dash+xml", at: "/dash/reel.mpd")
        site.serve(video: 912_345, at: "/dash/video-720.mp4")
        site.serve(video: 81_234, type: "audio/mp4", at: "/dash/audio.m4a")

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/dash/reel.mpd"), kind: .manifest)] }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let versions = candidates.flatMap(\.versions)
        let both: Int64 = 912_345 + 81_234
        #expect(versions.first { !$0.isAudio }?.totalBytes == both)
        #expect(versions.first(where: \.isAudio)?.totalBytes == 81_234)
        #expect(versions.allSatisfy { !$0.isEstimatedSize })
    }

    @Test func anHLSVersionOfByteRangesWithItsAudioUsesTheRangeEnds() async throws {
        let site = try await Site()
        site.serve(html: "<title>Clip</title>", at: "/watch")
        site.serve(text: """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="a"
            video.m3u8
            """, at: "/hls/master.m3u8")
        site.serve(text: Self.byteRanges(of: "video.mp4", ends: [999, 50_999, 120_999]), at: "/hls/video.m3u8")
        site.serve(text: Self.byteRanges(of: "audio.mp4", ends: [499, 9_999, 20_999]), at: "/hls/audio.m3u8")

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/hls/master.m3u8"), kind: .manifest)] }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let video = candidates.flatMap(\.versions).first { !$0.isAudio }
        let both: Int64 = 121_000 + 21_000
        #expect(video?.totalBytes == both)
        #expect(video?.isEstimatedSize == false)
    }

    @Test func otherHLSVersionsEstimateFromThreeSampleFragments() async throws {
        let site = try await Site()
        site.serve(html: "<title>Clip</title>", at: "/watch")
        let sizes = [10_000, 20_000, 30_000, 40_000, 50_000, 60_000]
        site.serve(text: """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-PLAYLIST-TYPE:VOD
            \(sizes.indices.map { "#EXTINF:6.0,\nseg\($0).ts" }.joined(separator: "\n"))
            #EXT-X-ENDLIST
            """, at: "/hls/video.m3u8")
        for (index, size) in sizes.enumerated() { site.serve(video: size, type: "video/mp2t", at: "/hls/seg\(index).ts") }

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/hls/video.m3u8"), kind: .manifest)] }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let video = candidates.flatMap(\.versions).first
        let sampled: Int64 = (20_000 + 40_000 + 60_000) / 3 * 6
        #expect(video?.totalBytes == sampled)
        #expect(video?.isEstimatedSize == true)
    }

    @Test func anHLSVersionWhoseSampleFailsKeepsItsBandwidthEstimate() async throws {
        let site = try await Site()
        site.serve(html: "<title>Clip</title>", at: "/watch")
        site.serve(text: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=900000,AVERAGE-BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"
            video.m3u8
            """, at: "/hls/master.m3u8")
        site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 6, named: "seg"), at: "/hls/video.m3u8")

        let found = try await site.analyze("/watch") { $0.watched = [WatchedRequest(url: site.url("/hls/master.m3u8"), kind: .manifest)] }

        guard case .found(let candidates) = found.withoutExtractedAudio else { Issue.record("not found: \(found)"); return }
        let video = candidates.flatMap(\.versions).first
        let fromAverageBandwidth: Int64 = 800_000 * 36 / 8
        #expect(video?.totalBytes == fromAverageBandwidth)
        #expect(video?.isEstimatedSize == true)
    }

    private static func byteRanges(of file: String, ends: [Int]) -> String {
        var starts = [0] + ends.dropLast().map { $0 + 1 }
        let mapEnd = starts.removeFirst() + ends[0]
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:6", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MAP:URI=\"\(file)\",BYTERANGE=\"\(mapEnd + 1)@0\""]
        for (start, end) in zip(starts, ends.dropFirst()) {
            lines += ["#EXTINF:6.0,", "#EXT-X-BYTERANGE:\(end - start + 1)@\(start)", file]
        }
        return (lines + ["#EXT-X-ENDLIST"]).joined(separator: "\n")
    }
}

private struct FixedReader: SiteReader {
    var video: SiteVideo
    var name: String { "Fixed" }
    func recognises(_ page: URL) -> Bool { page.path.hasPrefix("/post/") }
    func post(in page: URL) -> String? { page.lastPathComponent }
    func read(_ page: SitePage) async throws -> [SiteVideo] { [video] }
}
