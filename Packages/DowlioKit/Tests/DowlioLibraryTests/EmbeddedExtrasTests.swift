import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)), .enabled(if: TestFFmpeg.isAvailable))
struct EmbeddedExtrasTests {
    static let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:01.500
        Hello

        00:00:01.500 --> 00:00:03.000
        Goodbye
        """

    private func serve(_ name: String, on server: TestServer) throws -> URL {
        server.serve(TestServer.File(data: try TestMedia.data(name)), at: "/\(name)")
        return server.url(for: "/\(name)")
    }

    private func subtitle(_ language: String, name: String, on server: TestServer) -> MediaExtras.Subtitle {
        server.serve(TestServer.File(data: Data(Self.vtt.utf8), headers: ["Content-Type": "text/vtt"]), at: "/subs/\(language).vtt")
        return MediaExtras.Subtitle(language: language, name: name, url: server.url(for: "/subs/\(language).vtt"), format: "vtt")
    }

    private func download(_ media: MediaSource, named name: String) async throws -> (DownloadRow, URL) {
        let fixture = try await LibraryFixture(remux: MediaRemuxer(ffmpeg: TestFFmpeg.helper).remux)
        var options = RequestOptions()
        options.fileName = name
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options)
        let row = try await fixture.library.row(id) { $0.hasEnded }
        return (row, fixture.folder.appending(path: name))
    }

    @Test func anMP4CarriesASubtitleTrackPerChosenLanguage() async throws {
        let server = try await TestServer()
        let media = try MediaSource(
            tracks: [
                MediaTrack(kind: .video, fragments: [MediaFragment(url: try serve("track-h264.mp4", on: server))], codecs: ["avc1.64000c"]),
                MediaTrack(kind: .audio, fragments: [MediaFragment(url: try serve("track-aac.m4a", on: server))], codecs: ["mp4a.40.2"]),
            ],
            container: .mp4,
            extras: MediaExtras(subtitles: [subtitle("en", name: "English", on: server), subtitle("bn", name: "Bangla", on: server)])
        )

        let (row, file) = try await download(media, named: "Clip.mp4")

        #expect(row.state == .completed)
        let described = try TestFFmpeg.describe(file)
        #expect(described.streams == ["video:h264", "audio:aac", "subtitle:mov_text", "subtitle:mov_text"])
        #expect(described.subtitleLanguages == ["eng", "ben"])
    }

    @Test func aWebMCarriesItsSubtitlesAsWebVTT() async throws {
        let server = try await TestServer()
        let media = try MediaSource(
            tracks: [
                MediaTrack(kind: .video, fragments: [MediaFragment(url: try serve("track-vp9.webm", on: server))], codecs: ["vp9"]),
                MediaTrack(kind: .audio, fragments: [MediaFragment(url: try serve("track-opus.webm", on: server))], codecs: ["opus"]),
            ],
            container: .webm,
            extras: MediaExtras(subtitles: [subtitle("en", name: "English", on: server)])
        )

        let (row, file) = try await download(media, named: "Clip.webm")

        #expect(row.state == .completed)
        let described = try TestFFmpeg.describe(file)
        #expect(described.streams == ["video:vp9", "audio:opus", "subtitle:webvtt"])
        #expect(described.subtitleLanguages == ["eng"])
    }

    @Test func aSubtitleThatCantBeFetchedDoesntStopTheDownload() async throws {
        let server = try await TestServer()
        let media = try MediaSource(
            tracks: [
                MediaTrack(kind: .video, fragments: [MediaFragment(url: try serve("track-h264.mp4", on: server))], codecs: ["avc1.64000c"]),
                MediaTrack(kind: .audio, fragments: [MediaFragment(url: try serve("track-aac.m4a", on: server))], codecs: ["mp4a.40.2"]),
            ],
            container: .mp4,
            extras: MediaExtras(subtitles: [MediaExtras.Subtitle(language: "en", name: "English", url: server.url(for: "/gone.vtt"), format: "vtt")])
        )

        let (row, file) = try await download(media, named: "Clip.mp4")

        #expect(row.state == .completed)
        #expect(try TestFFmpeg.describe(file).streams == ["video:h264", "audio:aac"])
    }

    private let chapters = [
        MediaExtras.Chapter(start: 0, end: 1.5, title: "Hello; and = welcome"),
        MediaExtras.Chapter(start: 1.5, end: 3, title: "Goodbye"),
    ]

    @Test func anMP4CarriesItsChaptersAndCoverArt() async throws {
        let server = try await TestServer()
        let media = try MediaSource(
            tracks: [
                MediaTrack(kind: .video, fragments: [MediaFragment(url: try serve("track-h264.mp4", on: server))], codecs: ["avc1.64000c"]),
                MediaTrack(kind: .audio, fragments: [MediaFragment(url: try serve("track-aac.m4a", on: server))], codecs: ["mp4a.40.2"]),
            ],
            container: .mp4,
            extras: MediaExtras(chapters: chapters, coverArt: try serve("cover.jpg", on: server))
        )

        let (row, file) = try await download(media, named: "Clip.mp4")

        #expect(row.state == .completed)
        let described = try TestFFmpeg.describe(file)
        #expect(described.chapters == 2)
        #expect(described.hasCoverArt)
        #expect(described.streams == ["video:h264", "audio:aac", "video:mjpeg"])
    }

    @Test func anM4ACarriesItsCoverArt() async throws {
        let server = try await TestServer()
        let media = try MediaSource(
            tracks: [MediaTrack(kind: .audio, fragments: [MediaFragment(url: try serve("track-aac.m4a", on: server))], codecs: ["mp4a.40.2"])],
            container: .m4a,
            extras: MediaExtras(coverArt: try serve("cover.jpg", on: server))
        )

        let (row, file) = try await download(media, named: "Song.m4a")

        #expect(row.state == .completed)
        let described = try TestFFmpeg.describe(file)
        #expect(described.hasCoverArt)
        #expect(described.streams == ["audio:aac", "video:mjpeg"])
    }

    @Test func aWebMCarriesItsChapters() async throws {
        let server = try await TestServer()
        let media = try MediaSource(
            tracks: [
                MediaTrack(kind: .video, fragments: [MediaFragment(url: try serve("track-vp9.webm", on: server))], codecs: ["vp9"]),
                MediaTrack(kind: .audio, fragments: [MediaFragment(url: try serve("track-opus.webm", on: server))], codecs: ["opus"]),
            ],
            container: .webm,
            extras: MediaExtras(chapters: chapters)
        )

        let (row, file) = try await download(media, named: "Clip.webm")

        #expect(row.state == .completed)
        let described = try TestFFmpeg.describe(file)
        #expect(described.chapters == 2)
        #expect(described.streams == ["video:vp9", "audio:opus"])
    }
}
