import AVFoundation
import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SeparateTracksTests {
    private func track(_ kind: MediaTrack.Kind, _ prefix: String, count: Int, on server: TestServer) throws -> MediaTrack {
        let paths = ["\(prefix)-init.mp4"] + (0..<count).map { "\(prefix)\($0).m4s" }
        let fragments = try paths.map { name in
            server.serve(TestServer.File(data: try TestMedia.data(name)), at: "/\(prefix)/\(name)")
            return MediaFragment(url: server.url(for: "/\(prefix)/\(name)"))
        }
        return MediaTrack(kind: kind, initialization: fragments[0], fragments: Array(fragments.dropFirst()))
    }

    private func options(_ name: String) -> RequestOptions {
        var options = RequestOptions()
        options.fileName = name
        return options
    }

    @Test func separateVideoAndAudioBecomeOneFileWithBothTracks() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let media = try MediaSource(tracks: [
            track(.video, "video", count: 3, on: server),
            track(.audio, "audio", count: 4, on: server),
        ])

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options("Clip.mp4"))
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(row.category == .video)
        var rows = await fixture.library.rows().makeAsyncIterator()
        #expect(await rows.next()?.count == 1)
        let asset = AVURLAsset(url: fixture.folder.appending(path: "Clip.mp4"))
        #expect(Set(try await asset.load(.tracks).map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }

    @Test func anAudioOnlyTrackSavesAsAnM4A() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let media = try MediaSource(tracks: [track(.audio, "audio", count: 4, on: server)])

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: RequestOptions())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(row.fileName.hasSuffix(".m4a"))
        #expect(row.category == .audio)
        let asset = AVURLAsset(url: fixture.folder.appending(path: row.fileName))
        #expect(try await asset.load(.tracks).map(\.mediaType) == [.audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }
}
