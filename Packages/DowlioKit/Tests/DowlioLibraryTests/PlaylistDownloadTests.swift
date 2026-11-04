import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioStore
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PlaylistDownloadTests {
    private struct Clip {
        let server: TestServer

        func serve(holding: Bool) throws {
            for name in ["track-h264.mp4", "track-aac.m4a", "track-vp9.webm", "track-opus.webm"] {
                server.serve(TestServer.File(data: try TestMedia.data(name), holdAfterBytes: holding ? 0 : nil), at: "/\(name)")
            }
        }

        func listed(_ entry: MediaSource) throws -> MediaSource {
            let audioOnly = entry.renewal?.choice?.audioOnly == true
            let renewal = MediaRenewal(pageURL: entry.renewal!.pageURL, formatIDs: audioOnly ? ["140"] : ["137", "140"])
            if audioOnly {
                return try MediaSource(tracks: [track(.audio, "track-aac.m4a", "mp4a.40.2")], container: .m4a, renewal: renewal)
            }
            return try MediaSource(tracks: [track(.video, "track-h264.mp4", "avc1.64000c"), track(.audio, "track-aac.m4a", "mp4a.40.2")], container: .mp4, renewal: renewal)
        }

        func listedAsWebM(_ entry: MediaSource) throws -> MediaSource {
            try MediaSource(
                tracks: [track(.video, "track-vp9.webm", "vp9"), track(.audio, "track-opus.webm", "opus")], container: .webm,
                renewal: MediaRenewal(pageURL: entry.renewal!.pageURL, formatIDs: ["315", "251"])
            )
        }

        private func track(_ kind: MediaTrack.Kind, _ name: String, _ codec: String) -> MediaTrack {
            MediaTrack(kind: kind, fragments: [MediaFragment(url: server.url(for: "/\(name)"))], codecs: [codec])
        }
    }

    private func entries(_ count: Int) -> [PlaylistListing.Entry] {
        (1...count).map { PlaylistListing.Entry(id: "v\($0)", position: $0, title: "Video \($0)", url: URL(string: "https://www.youtube.com/watch?v=v\($0)")!) }
    }

    private func add(
        _ entries: [PlaylistListing.Entry], to fixture: LibraryFixture, showing: SentPageDraft.Showing = .video, folders: Bool = false
    ) async -> [DownloadID] {
        var ids: [DownloadID] = []
        for entry in entries {
            let media = PlaylistNaming.media(for: entry, showing: showing, quality: .upTo(1080), subtitles: [])
            var options = RequestOptions()
            options.fileName = PlaylistNaming.fileName(position: entry.position, of: entries.count, title: entry.title, fileExtension: media.fileExtension)
            options.subfolder = PlaylistNaming.folderName("Mix: Best of")
            options.playlistGroup = "PL1"
            let destination: Destination = folders ? .categoryFolders(under: fixture.folder) : .folder(fixture.folder)
            ids.append(await fixture.library.add(.media(media), destination: destination, options: options))
        }
        return ids
    }

    @Test func aPlaylistsVideosDownloadThreeAtATimeAndTheRestWaitQueued() async throws {
        let clip = Clip(server: try await TestServer())
        try clip.serve(holding: true)
        let fixture = try await LibraryFixture(renew: { try clip.listed($0) })
        await fixture.library.setMaximumActive(10)

        let ids = await add(entries(5), to: fixture)
        let waiting = try await fixture.library.firstRows { rows in rows.filter { $0.state == .queued }.count == 2 }

        #expect(waiting.filter { $0.state == .downloading }.count == 3)
        clip.server.releaseHeldResponses()
        for id in ids { _ = try await fixture.library.row(id) { $0.state == .completed } }
    }

    @Test func aVideoThatFailsBecomesFailedWithItsReasonAndTheRestCarryOn() async throws {
        let clip = Clip(server: try await TestServer())
        try clip.serve(holding: false)
        let fixture = try await LibraryFixture(renew: { entry in
            if entry.renewal?.pageURL.query()?.contains("v=v2") == true { throw DownloadError.notFound }
            return try clip.listed(entry)
        })

        let ids = await add(entries(4), to: fixture)

        let failed = try await fixture.library.row(ids[1]) { $0.hasEnded }
        #expect(failed.state == .failed(.notFound))
        for id in [ids[0], ids[2], ids[3]] { _ = try await fixture.library.row(id) { $0.state == .completed } }
    }

    @Test func filesGoIntoAFolderNamedAfterThePlaylistInsideTheCategoryFolderNumberedInOrder() async throws {
        let clip = Clip(server: try await TestServer())
        try clip.serve(holding: false)
        let fixture = try await LibraryFixture(renew: { try clip.listed($0) })

        let videos = await add(entries(2), to: fixture, folders: true)
        for id in videos { _ = try await fixture.library.row(id) { $0.state == .completed } }

        let folder = fixture.folder.appending(path: "Video/Mix- Best of")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["01 Video 1.mp4", "02 Video 2.mp4"])
    }

    @Test func audioOnlyGoesIntoTheAudioFolder() async throws {
        let clip = Clip(server: try await TestServer())
        try clip.serve(holding: false)
        let fixture = try await LibraryFixture(renew: { try clip.listed($0) })

        let songs = await add(entries(1), to: fixture, showing: .audio, folders: true)
        _ = try await fixture.library.row(songs[0]) { $0.state == .completed }

        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "Audio/Mix- Best of/01 Video 1.m4a").path))
    }

    @Test(.enabled(if: TestFFmpeg.isAvailable))
    func aVideoThatComesBackAsWebMIsNamedWebM() async throws {
        let clip = Clip(server: try await TestServer())
        try clip.serve(holding: false)
        let fixture = try await LibraryFixture(remux: MediaRemuxer(ffmpeg: TestFFmpeg.helper).remux, renew: { try clip.listedAsWebM($0) })

        let ids = await add(entries(1), to: fixture)
        let row = try await fixture.library.row(ids[0]) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(row.fileName == "01 Video 1.webm")
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "Mix- Best of/01 Video 1.webm").path))
    }

    @Test func eachVideoIsItsOwnDownloadInHistory() async throws {
        let clip = Clip(server: try await TestServer())
        try clip.serve(holding: false)
        let fixture = try await LibraryFixture(renew: { try clip.listed($0) })

        let ids = await add(entries(3), to: fixture)
        for id in ids { _ = try await fixture.library.row(id) { $0.state == .completed } }

        let stored = try DownloadStore(databaseAt: fixture.databaseURL).all()
        #expect(Set(stored.map(\.id)) == Set(ids.map(\.rawValue)))
        #expect(stored.allSatisfy { $0.playlistGroup == "PL1" && $0.subfolder == "Mix- Best of" })
    }

    @Test func numbersAreWideEnoughForThePlaylist() {
        #expect(PlaylistNaming.fileName(position: 3, of: 20, title: "Song", fileExtension: "m4a") == "03 Song.m4a")
        #expect(PlaylistNaming.fileName(position: 7, of: 140, title: "Lesson", fileExtension: "mp4") == "007 Lesson.mp4")
        #expect(PlaylistNaming.fileName(position: 1, of: 5, title: "A/B: C", fileExtension: "mp4") == "01 A-B- C.mp4")
        #expect(PlaylistNaming.folderName("..") == "Playlist")
    }

    @Test func anEntryThatCantBeListedNeedsTheTools() async throws {
        let fixture = try await LibraryFixture()

        let ids = await add(entries(1), to: fixture)
        let row = try await fixture.library.row(ids[0]) { $0.hasEnded }

        #expect(row.state == .failed(.needsTools))
    }
}
