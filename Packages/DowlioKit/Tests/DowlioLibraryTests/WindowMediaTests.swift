import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct WindowMediaTests {
    private func file(_ name: String, height: Int? = nil, bytes: Int64? = nil, type: String = "video/mp4") -> Version {
        Version(source: .file(URL(string: "https://cdn.example.com/\(name)")!), contentType: type, totalBytes: bytes, height: height)
    }

    @Test func aFoundVideoShowsItsBestResolutionSizeAndLength() {
        let candidate = Candidate(label: "Clip", duration: 192, versions: [file("a.mp4", height: 480, bytes: 10_000_000), file("b.mp4", height: 1080, bytes: 52_000_000)])

        #expect(MediaText.summary(of: candidate) == "1080p · 52.0 MB · 3:12 · 2 versions")
    }

    @Test func aVideoWithOneVersionAndNothingKnownShowsItsFileType() {
        let candidate = Candidate(label: "Clip", versions: [file("a.mp4")])

        #expect(MediaText.summary(of: candidate) == "MP4")
    }

    @Test func extractedAudioIsNotCountedAsAnotherVersion() throws {
        let video = file("a.mp4", height: 720, bytes: 1_000_000)
        let audio = try #require(Version.extractedAudio(of: video))
        let candidate = Candidate(label: "Clip", versions: [video, audio])

        #expect(MediaText.summary(of: candidate) == "720p · 1.00 MB")
    }
}
