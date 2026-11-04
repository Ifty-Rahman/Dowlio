import AVFoundation
import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YouTubeDownloadTests {
    private func track(_ kind: MediaTrack.Kind, _ name: String, codecs: [String], on server: TestServer, holding: Bool = false) throws -> MediaTrack {
        let data = try TestMedia.data(name)
        server.serve(TestServer.File(data: data, holdAfterBytes: holding ? 0 : nil), at: "/\(name)")
        return MediaTrack(kind: kind, fragments: [MediaFragment(url: server.url(for: "/\(name)"), bytes: 0...Int64(data.count - 1))], codecs: codecs)
    }

    private func clip(on server: TestServer, holding: Bool = false) throws -> MediaSource {
        try MediaSource(
            tracks: [
                track(.video, "track-h264.mp4", codecs: ["avc1.64000c"], on: server, holding: holding),
                track(.audio, "track-aac.m4a", codecs: ["mp4a.40.2"], on: server, holding: holding),
            ],
            container: .mp4,
            renewal: MediaRenewal(pageURL: URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!, formatIDs: ["137", "140"])
        )
    }

    private func options(limit: Int64?) -> RequestOptions {
        var options = RequestOptions()
        options.fileName = "Perfect.mp4"
        options.connections = 4
        options.requestSizeLimit = limit
        return options
    }

    private static func requestedLength(_ range: String) -> Int64? {
        let bounds = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int64($0) }
        return bounds.count == 2 ? bounds[1] - bounds[0] + 1 : nil
    }

    @Test func noRangeLargerThanTheRequestSizeLimitReachesTheServerAndTheTracksJoinIntoOneMP4() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()

        let id = await fixture.library.add(.media(try clip(on: server)), destination: .folder(fixture.folder), options: options(limit: 4096))
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        let ranges = server.requests.compactMap { $0.headers["range"] }
        #expect(ranges.count >= 33_444 / 4096 + 13_570 / 4096)
        #expect(ranges.allSatisfy { (Self.requestedLength($0) ?? .max) <= 4096 })
        let asset = AVURLAsset(url: fixture.folder.appending(path: "Perfect.mp4"))
        #expect(Set(try await asset.load(.tracks).map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }

    @Test func limitedRangesStillDownloadOverParallelConnections() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()

        let id = await fixture.library.add(.media(try clip(on: server, holding: true)), destination: .folder(fixture.folder), options: options(limit: 4096))
        try await waitUntil { server.openConnections(at: "/track-h264.mp4") + server.openConnections(at: "/track-aac.m4a") >= 3 }
        server.releaseHeldResponses()
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
    }

    @Test func aYouTubeDownloadPausedBeforeAQuitResumesAndFinishes() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let id = await fixture.library.add(.media(try clip(on: server, holding: true)), destination: .folder(fixture.folder), options: options(limit: 4096))
        try await waitUntil { server.openConnections(at: "/track-h264.mp4") > 0 }
        await fixture.library.pause(id)
        _ = try await fixture.library.row(id) { $0.state == .paused }

        let relaunched = try await fixture.relaunched()
        server.releaseHeldResponses()
        await relaunched.library.resume(id)
        let row = try await relaunched.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "Perfect.mp4").path))
    }

    @Test func cancellingAYouTubeDownloadDeletesItsPartialFile() async throws {
        let server = try await TestServer()
        let fixture = try await LibraryFixture()
        let id = await fixture.library.add(.media(try clip(on: server, holding: true)), destination: .folder(fixture.folder), options: options(limit: 4096))
        try await waitUntil { server.openConnections(at: "/track-h264.mp4") > 0 }

        await fixture.library.cancel(id)
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: fixture.folder.path))?.isEmpty == true }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty)
    }
}

struct YouTubeDraftTests {
    private func video(_ height: Int?, audio: Bool = false) throws -> Version {
        let url = URL(string: "https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=\(height ?? 140)")!
        let media = try MediaSource(tracks: [MediaTrack(kind: audio ? .audio : .video, fragments: [MediaFragment(url: url)])], container: audio ? .m4a : .mp4)
        return Version(source: .media(media), height: height, codecs: audio ? "AAC" : "H.264 + AAC")
    }

    @Test func aYouTubeMusicVideoOpensOnAudioOnly() throws {
        let song = Candidate(label: "Perfect", versions: [try video(1080), try video(720), try video(nil, audio: true)], opensAsAudio: true)
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://music.youtube.com/watch?v=2Vv-BfVoq4g")!))

        _ = draft.update(.found([song]))

        #expect(draft.showing == .audio)
        #expect(draft.chosenVersion?.isAudio == true)
    }

    @Test func theQualitySettingPicksTheDefaultRowAndRowsNameTheirCodec() throws {
        let clip = Candidate(label: "Perfect", versions: [try video(1080), try video(720), try video(nil, audio: true)])
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!), preference: QualityPreference(quality: .upTo(720)))

        _ = draft.update(.found([clip]))

        #expect(draft.chosenVersion?.height == 720)
        #expect(draft.chosenVersion.map(MediaText.detail) == "MP4 · H.264 + AAC")
    }
}
