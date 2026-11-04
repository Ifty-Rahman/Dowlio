import AVFoundation
import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WebMTracksTests {
    private func track(_ kind: MediaTrack.Kind, _ name: String, codecs: [String], on server: TestServer) throws -> MediaTrack {
        server.serve(TestServer.File(data: try TestMedia.data(name)), at: "/\(name)")
        return MediaTrack(kind: kind, fragments: [MediaFragment(url: server.url(for: "/\(name)"))], codecs: codecs)
    }

    private func options(_ name: String) -> RequestOptions {
        var options = RequestOptions()
        options.fileName = name
        return options
    }

    @Test(.enabled(if: TestFFmpeg.isAvailable))
    func vp9WithOpusFinishesAsOneWebMWithBothTracks() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture(remux: MediaRemuxer(ffmpeg: TestFFmpeg.helper).remux)
        let media = try MediaSource(
            tracks: [
                track(.video, "track-vp9.webm", codecs: ["vp9"], on: server),
                track(.audio, "track-opus.webm", codecs: ["opus"], on: server),
            ],
            container: .webm
        )

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options("Clip.webm"))
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(row.fileName == "Clip.webm")
        let file = try TestFFmpeg.describe(fixture.folder.appending(path: "Clip.webm"))
        #expect(file.streams == ["video:vp9", "audio:opus"])
        #expect(abs((file.duration ?? 0) - 3) < 0.3)
    }

    @Test func h264WithAACJoinsThroughAVFoundationEvenWithAHelper() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture(remux: MediaRemuxer(ffmpeg: URL(fileURLWithPath: "/usr/bin/false")).remux)
        let media = try MediaSource(tracks: [
            track(.video, "track-h264.mp4", codecs: ["avc1.64000c"], on: server),
            track(.audio, "track-aac.m4a", codecs: ["mp4a.40.2"], on: server),
        ])

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options("Clip.mp4"))
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        let asset = AVURLAsset(url: fixture.folder.appending(path: "Clip.mp4"))
        #expect(Set(try await asset.load(.tracks).map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }

    @Test func vp9WithOpusFailsAsUnplayableWithoutTheHelper() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture(remux: MediaRemuxer(ffmpeg: nil).remux)
        let media = try MediaSource(
            tracks: [
                track(.video, "track-vp9.webm", codecs: ["vp9"], on: server),
                track(.audio, "track-opus.webm", codecs: ["opus"], on: server),
            ],
            container: .webm
        )

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options("Clip.webm"))
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .failed(.mediaUnplayable))
    }
}
