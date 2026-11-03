import AVFoundation
import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HLSDownloadTests {
    private func serve(_ names: [String], on server: TestServer, under folder: String, hold: Bool = false) throws -> [MediaFragment] {
        try names.map { name in
            let path = "/\(folder)/\(name)"
            server.serve(TestServer.File(data: try TestMedia.data(name), holdAfterBytes: hold ? 0 : nil), at: path)
            return MediaFragment(url: server.url(for: path))
        }
    }

    private func options(connections: Int = 8) -> RequestOptions {
        var options = RequestOptions()
        options.fileName = "clip.mp4"
        options.connections = connections
        return options
    }

    private func checkPlays(_ file: URL) async throws {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.load(.tracks)
        #expect(Set(tracks.map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }

    @Test func transportStreamSegmentsBecomeOneMP4ThatPlays() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let fragments = try serve(["ts0.ts", "ts1.ts", "ts2.ts"], on: server, under: "ts")
        let media = try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: fragments)])

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(row.fileName == "clip.mp4")
        try await checkPlays(fixture.folder.appending(path: "clip.mp4"))
        #expect(TestFiles.partialFiles(in: fixture.folder).isEmpty)
    }

    @Test func fragmentedMP4SegmentsFollowTheirInitSegment() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let pieces = try serve(["init.mp4", "frag0.m4s", "frag1.m4s", "frag2.m4s"], on: server, under: "fmp4")
        let media = try MediaSource(tracks: [MediaTrack(kind: .combined, initialization: pieces[0], fragments: Array(pieces.dropFirst()))])

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        try await checkPlays(fixture.folder.appending(path: "clip.mp4"))
    }

    @Test func segmentsThatAreRangesOfOneFileAreCutFromIt() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let parts = try ["ts0.ts", "ts1.ts", "ts2.ts"].map { try TestMedia.data($0) }
        server.serve(TestServer.File(data: parts.reduce(Data(), +)), at: "/one/all.ts")
        var offset: Int64 = 0
        let fragments = parts.map { part in
            defer { offset += Int64(part.count) }
            return MediaFragment(url: server.url(for: "/one/all.ts"), bytes: offset...(offset + Int64(part.count) - 1))
        }
        let media = try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: fragments)])

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        try await checkPlays(fixture.folder.appending(path: "clip.mp4"))
    }

    @Test func segmentsDownloadNoMoreAtOnceThanTheConnectionSetting() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let names = ["ts0.ts", "ts1.ts", "ts2.ts"]
        let fragments = try serve(names, on: server, under: "a", hold: true) + serve(names, on: server, under: "b", hold: true)
        let paths = fragments.map(\.url.path)
        let open: @Sendable () -> Int = { paths.map { server.openConnections(at: $0) }.reduce(0, +) }
        let media = try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: fragments)])

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options(connections: 2))
        try await waitUntil { open() == 2 }
        try await Task.sleep(for: .milliseconds(200))
        let peak = open()
        server.releaseHeldResponses()
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(peak == 2)
        #expect(row.state == .completed)
    }

    @Test func aPausedVideoResumesAfterARelaunchWithoutFetchingFinishedSegmentsAgain() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        var fragments = try serve(["ts0.ts", "ts1.ts"], on: server, under: "r")
        fragments += try serve(["ts2.ts"], on: server, under: "r", hold: true)
        let media = try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: fragments)])
        let firstTwo = Int64(try TestMedia.data("ts0.ts").count + TestMedia.data("ts1.ts").count)

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        _ = try await fixture.library.row(id) { $0.receivedBytes >= firstTwo }
        await fixture.library.pause(id)
        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { _ in true }
        server.releaseHeldResponses()
        await relaunched.library.resume(id)
        let row = try await relaunched.library.row(id) { $0.hasEnded }

        #expect(restored.state == .paused)
        #expect(restored.receivedBytes >= firstTwo)
        #expect(row.state == .completed)
        #expect(server.requests.filter { $0.path == "/r/ts0.ts" }.count == 1)
        try await checkPlays(fixture.folder.appending(path: "clip.mp4"))
    }

    @Test func aSegmentRefusedOnResumeMeansTheLinkExpired() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        var fragments = try serve(["ts0.ts"], on: server, under: "x")
        fragments += try serve(["ts1.ts"], on: server, under: "x", hold: true)
        let media = try MediaSource(tracks: [MediaTrack(kind: .combined, fragments: fragments)])
        let first = Int64(try TestMedia.data("ts0.ts").count)

        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        _ = try await fixture.library.row(id) { $0.receivedBytes >= first }
        await fixture.library.pause(id)
        server.serve(TestServer.File(data: try TestMedia.data("ts1.ts"), failFirst: .init(status: 403)), at: "/x/ts1.ts")
        let relaunched = try await fixture.relaunched()
        _ = try await relaunched.library.row(id) { _ in true }
        await relaunched.library.resume(id)
        let row = try await relaunched.library.row(id) { $0.hasEnded }

        #expect(row.state == .failed(.linkExpired))
        #expect(row.detailLine == "Link expired · Send the page again")
    }
}

extension DownloadRow {
    var hasEnded: Bool {
        if case .failed = state { return true }
        return state == .completed
    }
}
