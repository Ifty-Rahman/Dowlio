import DowlioCore
import DowlioMedia
import Foundation
import Testing

struct MPDParserTests {
    private func fixture(_ name: String, at base: String = "https://cdn.example.com/dash/stream.mpd") throws -> DASHManifest {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Streams/\(name)", withExtension: "mpd"))
        return try MPDParser.parse(Data(contentsOf: url), base: URL(string: base)!)
    }

    @Test func aTemplateManifestListsEveryRepresentationWithItsFragments() throws {
        let manifest = try fixture("dash-static")

        #expect(!manifest.isDynamic)
        #expect(!manifest.isProtected)
        #expect(manifest.duration == 634.566)
        let videos = manifest.tracks.filter { $0.kind == .video }
        let audio = try #require(manifest.tracks.first { $0.kind == .audio })
        #expect(videos.count == 10)
        let first = try #require(videos.first)
        #expect(first.height == 576)
        #expect(first.bandwidth == 3_134_488)
        #expect(first.codecs == ["avc1.64001f"])
        #expect(first.initialization?.url == URL(string: "https://cdn.example.com/dash/bbb_30fps_1024x576_2500k/bbb_30fps_1024x576_2500k_0.m4v"))
        #expect(first.fragments.count == 159)
        #expect(first.fragments.first?.url == URL(string: "https://cdn.example.com/dash/bbb_30fps_1024x576_2500k/bbb_30fps_1024x576_2500k_1.m4v"))
        #expect(first.fragments.last?.url.lastPathComponent == "bbb_30fps_1024x576_2500k_159.m4v")
        #expect(audio.fragments.count == 159)
        #expect(audio.codecs == ["mp4a.40.5"])
    }

    @Test func aSegmentBaseRepresentationIsItsWholeFile() throws {
        let manifest = try fixture("dash-static-languages-and-text")

        let video = try #require(manifest.tracks.first { $0.id == "6" })
        #expect(video.kind == .video)
        #expect(video.fragments == [MediaFragment(url: URL(string: "https://cdn.example.com/dash/" + video.fragments[0].url.lastPathComponent)!)])
        #expect(video.initialization == nil)
        let spanish = try #require(manifest.tracks.first { $0.id == "4" })
        #expect(spanish.kind == .audio)
        #expect(spanish.language == "es")
        #expect(manifest.tracks.contains { $0.kind == .other })
    }

    @Test func protectionAndLiveAreNoticed() throws {
        #expect(try fixture("dash-widevine").isProtected)
        #expect(try fixture("dash-dynamic").isDynamic)
    }

    @Test func aSegmentListAndATimelineAreRead() throws {
        let manifest = try MPDParser.parse(Data("""
            <MPD type="static" mediaPresentationDuration="PT6S">
              <BaseURL>https://media.example/v/</BaseURL>
              <Period>
                <AdaptationSet mimeType="video/mp4">
                  <Representation id="list" bandwidth="1000" height="360" codecs="avc1.4d401e">
                    <SegmentList>
                      <Initialization sourceURL="init.mp4"/>
                      <SegmentURL media="a.m4s"/>
                      <SegmentURL media="all.mp4" mediaRange="100-199"/>
                    </SegmentList>
                  </Representation>
                </AdaptationSet>
                <AdaptationSet mimeType="audio/mp4">
                  <SegmentTemplate timescale="1000" initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/$Time$-$Number%03d$.m4s" startNumber="7">
                    <SegmentTimeline>
                      <S t="0" d="2000" r="1"/>
                      <S d="2000"/>
                    </SegmentTimeline>
                  </SegmentTemplate>
                  <Representation id="aac" bandwidth="128000" codecs="mp4a.40.2"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """.utf8), base: URL(string: "https://site.example/manifest.mpd")!)

        let list = try #require(manifest.tracks.first { $0.id == "list" })
        #expect(list.initialization == MediaFragment(url: URL(string: "https://media.example/v/init.mp4")!))
        #expect(list.fragments == [
            MediaFragment(url: URL(string: "https://media.example/v/a.m4s")!),
            MediaFragment(url: URL(string: "https://media.example/v/all.mp4")!, bytes: 100...199),
        ])
        let audio = try #require(manifest.tracks.first { $0.id == "aac" })
        #expect(audio.fragments.map(\.url.lastPathComponent) == ["0-007.m4s", "2000-008.m4s", "4000-009.m4s"])
    }

    @Test func somethingThatIsntAManifestIsRefused() {
        #expect(throws: MPDParser.Error.notAManifest) {
            try MPDParser.parse(Data("<html></html>".utf8), base: URL(string: "https://a.example/x.mpd")!)
        }
    }
}

extension MPDParserTests {
    @Test func protectionOnThePeriodCounts() throws {
        let manifest = try MPDParser.parse(Data("""
            <MPD type="static" mediaPresentationDuration="PT4S"><Period>
              <ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"/>
              <AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1"><BaseURL>v.mp4</BaseURL></Representation></AdaptationSet>
            </Period></MPD>
            """.utf8), base: URL(string: "https://a.example/m.mpd")!)

        #expect(manifest.isProtected)
    }
}
