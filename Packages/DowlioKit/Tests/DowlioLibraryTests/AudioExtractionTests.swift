import AVFoundation
import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AudioExtractionTests {
    private func checkIsAudioOnly(_ file: URL) async throws {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.load(.tracks)
        #expect(tracks.map(\.mediaType) == [.audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }

    private func options(_ name: String) -> RequestOptions {
        var options = RequestOptions()
        options.fileName = name
        return options
    }

    @Test func theAudioOfAStreamedVideoIsSavedAsAnM4AInTheAudioCategory() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let fragments = try ["ts0.ts", "ts1.ts", "ts2.ts"].map { name in
            server.serve(TestServer.File(data: try TestMedia.data(name)), at: "/ts/\(name)")
            return MediaFragment(url: server.url(for: "/ts/\(name)"))
        }
        let video = Version(
            source: .media(try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: fragments)])),
            contentType: "video/mp4", totalBytes: 900_000, isEstimatedSize: true, height: 360, codecs: "H.264 + AAC"
        )
        let audio = try #require(Version.extractedAudio(of: video))

        let id = await fixture.library.add(audio.source, destination: .folder(fixture.folder), options: options("Clip.m4a"))
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(row.fileName == "Clip.m4a")
        #expect(row.category == .audio)
        try await checkIsAudioOnly(fixture.folder.appending(path: "Clip.m4a"))
    }

    @Test func theAudioOfAWholeVideoFileIsTakenFromItInRanges() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let joined = fixture.folder.deletingLastPathComponent().appending(path: "joined.ts")
        try ["ts0.ts", "ts1.ts", "ts2.ts"].map { try TestMedia.data($0) }.reduce(Data(), +).write(to: joined)
        let whole = fixture.folder.deletingLastPathComponent().appending(path: "whole.mp4")
        try await AVRemuxer.remux([joined], to: whole)
        let data = try Data(contentsOf: whole)
        server.serve(TestServer.File(data: data, headers: ["Content-Type": "video/mp4"]), at: "/clip.mp4")
        let video = Version(source: .file(server.url(for: "/clip.mp4")), contentType: "video/mp4", totalBytes: Int64(data.count))
        let audio = try #require(Version.extractedAudio(of: video, splitsIntoSegments: true, rangeSize: 4096))

        let id = await fixture.library.add(audio.source, destination: .folder(fixture.folder), options: options("Clip.m4a"))
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(server.requests.filter { $0.path == "/clip.mp4" }.count > 1)
        try await checkIsAudioOnly(fixture.folder.appending(path: "Clip.m4a"))
    }
}
