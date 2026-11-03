import DowlioCore
import DowlioEngine
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ExtractedAudioTests {
    @Test func everyVideoGetsAnAudioVersionTakenFromItsSmallestVersion() async throws {
        let site = try await Site()
        site.serve(html: """
            <title>Two sizes</title>
            <video><source src="/media/clip-720p.mp4" type="video/mp4"><source src="/media/clip-360p.mp4" type="video/mp4"></video>
            """, at: "/watch")
        site.serve(video: 9000, at: "/media/clip-720p.mp4")
        site.serve(video: 3000, at: "/media/clip-360p.mp4")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found, let video = candidates.first else { Issue.record("not found: \(found)"); return }
        let audio = video.versions.filter(\.isExtractedAudio)
        #expect(audio.count == 1)
        #expect(audio.first?.totalBytes == 3000)
        #expect(audio.first?.contentType == "audio/mp4")
        #expect(audio.first?.source.url == site.url("/media/clip-360p.mp4"))
    }

    @Test func aCandidateThatIsAlreadyAudioGetsNoExtractedVersion() async throws {
        let site = try await Site()
        site.serve(html: #"<title>Both</title><video src="/media/clip.mp4"></video><audio src="/media/clip.m4a"></audio>"#, at: "/watch")
        site.serve(video: 9000, at: "/media/clip.mp4")
        site.serve(video: 900, type: "audio/mp4", at: "/media/clip.m4a")

        let found = try await site.analyze("/watch")

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.flatMap(\.versions).filter(\.isExtractedAudio).count == 1)
        #expect(candidates.filter { $0.versions.allSatisfy { $0.contentType?.hasPrefix("audio/") == true } }.map(\.versions.count) == [1])
    }

    @Test func aVideoWhoseAudioIsSeparateIsntExtracted() throws {
        let fragment = MediaFragment(url: URL(string: "https://cdn.example/v/0.m4s")!)
        let video = Version(source: .media(try MediaSource(tracks: [MediaTrack(kind: .video, fragments: [fragment])])), contentType: "video/mp4")

        #expect(Version.extractedAudio(of: video) == nil)
    }

    @Test func videosWhoseAudioCantGoInAnM4AArentExtracted() {
        let webm = Version(source: .file(URL(string: "https://cdn.example/a.webm")!), contentType: "video/webm", totalBytes: 10)
        let opus = Version(source: .file(URL(string: "https://cdn.example/a.mp4")!), contentType: "video/mp4", totalBytes: 10, codecs: "VP9 + Opus")

        #expect(Version.extractedAudio(of: webm) == nil)
        #expect(Version.extractedAudio(of: opus) == nil)
    }

    @Test func theExtractedVersionNamesTheAudioCodecOnly() throws {
        let video = Version(source: .file(URL(string: "https://cdn.example/a.mp4")!), contentType: "video/mp4", totalBytes: 10, codecs: "H.264 + AAC")

        #expect(Version.extractedAudio(of: video)?.codecs == "AAC")
        #expect(Version.extractedAudio(of: Version(source: video.source, codecs: "H.264"))?.codecs == nil)
    }
}
