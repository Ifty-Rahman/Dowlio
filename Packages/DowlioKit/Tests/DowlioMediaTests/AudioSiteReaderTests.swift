import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AudioSiteReaderTests {
    private func placeholders(_ site: ReaderSite) -> [String: String] {
        ["{{server}}": String(site.url("/").absoluteString.dropLast())]
    }

    private func soundCloud() async throws -> ReaderSite {
        let site = try await ReaderSite { SoundCloudReader(hosts: ["127.0.0.1"], api: $0.url(for: "/api/")) }
        let fill = placeholders(site)
        try site.serve(fixture: "soundcloud-page.html", at: "/sample-artist/sample-track", replacing: fill)
        try site.serve(fixture: "soundcloud-app.js", at: "/assets/app-sample.js")
        site.site.serve(text: "var nothing = 1;", type: "application/javascript", at: "/assets/0-sample.js")
        try site.serve(fixture: "soundcloud-track.json", at: "/api/resolve", replacing: fill)
        try site.serve(fixture: "soundcloud-progressive.json", at: "/media/sample/stream/progressive", replacing: fill)
        try site.serve(fixture: "soundcloud-hls-aac.json", at: "/media/sample/stream/hls-aac", replacing: fill)
        site.site.serve(video: 3_400_000, type: "audio/mpeg", at: "/audio/sample.mp3")
        site.site.serve(text: PageAnalyzerTests.mediaPlaylist(segments: 2, named: "a"), at: "/audio/sample-aac/playlist.m3u8")
        for index in 0..<2 { site.site.serve(video: 100_000, type: "audio/mp4", at: "/audio/sample-aac/a\(index).ts") }
        return site
    }

    @Test func aSoundCloudTrackListsItsProgressiveMP3AndItsHLSAACAsAudioOnly() async throws {
        let site = try await soundCloud()

        let candidates = try await site.candidates("/sample-artist/sample-track")

        let track = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(track.label == "Sample Artist - Sample Track")
        #expect(track.duration == 215)
        #expect(track.versions.count == 2)
        #expect(track.versions.allSatisfy { $0.isAudio })
        #expect(track.versions.contains { $0.contentType == "audio/mpeg" && $0.totalBytes == 3_400_000 })
        #expect(!track.versions.contains { $0.isExtractedAudio })
    }

    @Test func aSoundCloudTrackReadsThePublicClientIDFromTheSitesScript() async throws {
        let site = try await soundCloud()

        _ = try await site.candidates("/sample-artist/sample-track")

        let resolve = site.site.server.requests.first { $0.path.hasPrefix("/api/resolve") }
        #expect(resolve?.path.contains("client_id=abcdefghijklmnopqrstuvwxyz123456") == true)
        let stream = site.site.server.requests.first { $0.path.hasPrefix("/media/sample/stream/progressive") }
        #expect(stream?.path.contains("track_authorization=auth-token-1") == true)
        #expect(!site.site.server.requests.contains { $0.path.hasPrefix("/media/sample/stream/hls-opus") })
    }

    @Test func soundCloudAddressesAreRecognisedByKind() {
        let reader = SoundCloudReader()
        #expect(reader.recognises(URL(string: "https://soundcloud.com/some-artist/some-track")!))
        #expect(reader.recognises(URL(string: "https://on.soundcloud.com/AbCdEf123")!))
        #expect(!reader.recognises(URL(string: "https://soundcloud.com/some-artist")!))
        #expect(!reader.recognises(URL(string: "https://soundcloud.com/some-artist/sets")!))
        #expect(!reader.recognises(URL(string: "https://soundcloud.com/discover/sets")!))
        #expect(reader.post(in: URL(string: "https://soundcloud.com/some-artist/some-track")!) == "some-artist/some-track")
    }

    @Test func aBandcampTrackListsItsFreeStreamAsAudioOnly() async throws {
        let site = try await ReaderSite { _ in BandcampReader(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "bandcamp-track.html", at: "/track/sample-track", replacing: placeholders(site))
        site.site.serve(video: 2_900_000, type: "audio/mpeg", at: "/stream/sample-track.mp3")

        let candidates = try await site.candidates("/track/sample-track")

        let track = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(track.label == "Sample Band - Sample Track")
        #expect(track.duration == 183.5)
        #expect(track.thumbnail == URL(string: "https://f4.bcbits.com/img/a1234567890_10.jpg"))
        #expect(track.versions.map { $0.isAudio } == [true])
        #expect(track.versions.compactMap(\.totalBytes) == [2_900_000])
    }

    @Test func aBandcampAlbumListsEachStreamableTrackAsItsOwnCandidate() async throws {
        let site = try await ReaderSite { _ in BandcampReader(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "bandcamp-album.html", at: "/album/sample-album", replacing: placeholders(site))
        site.site.serve(video: 1_000_000, type: "audio/mpeg", at: "/stream/first.mp3")
        site.site.serve(video: 2_000_000, type: "audio/mpeg", at: "/stream/second.mp3")

        let candidates = try await site.candidates("/album/sample-album")

        #expect(candidates.map(\.label) == ["Sample Band - First Song", "Sample Band - Second Song"])
    }

    @Test func bandcampAddressesAreRecognisedByKind() {
        let reader = BandcampReader()
        #expect(reader.recognises(URL(string: "https://artist.bandcamp.com/track/some-song")!))
        #expect(reader.recognises(URL(string: "https://artist.bandcamp.com/album/some-album")!))
        #expect(reader.post(in: URL(string: "https://artist.bandcamp.com/track/some-song")!) == "some-song")
        #expect(!reader.recognises(URL(string: "https://artist.bandcamp.com/music")!))
        #expect(!reader.recognises(URL(string: "https://bandcamp.com/")!))
    }

    @Test func aMixcloudShowWithAPlainStreamListsItAsAudioOnly() async throws {
        let site = try await ReaderSite { _ in MixcloudReader(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "mixcloud-show.html", at: "/sample-dj/sample-show/", replacing: placeholders(site))
        site.site.serve(video: 50_000_000, type: "audio/mp4", at: "/stream/sample-show.m4a")

        let candidates = try await site.candidates("/sample-dj/sample-show/")

        let show = try #require(candidates.first)
        #expect(show.label == "Sample DJ - Sample Show")
        #expect(show.duration == 3600)
        #expect(show.versions.map { $0.isAudio } == [true])
        #expect(show.versions.compactMap(\.totalBytes) == [50_000_000])
    }

    @Test func aMixcloudShowWithEncodedStreamAddressesIsLeftOutAndLogged() async throws {
        let site = try await ReaderSite { _ in MixcloudReader(hosts: ["127.0.0.1"]) }
        try site.serve(fixture: "mixcloud-encrypted.html", at: "/sample-dj/sample-show/")

        let found = try await site.site.analyze("/sample-dj/sample-show/")

        if case .found(let candidates) = found.withoutExtractedAudio { #expect(candidates.allSatisfy { $0.versions.isEmpty }) }
        #expect(site.log.failures.contains { $0.reader == "Mixcloud" })
    }

    @Test func mixcloudAddressesAreRecognisedByKind() {
        let reader = MixcloudReader()
        #expect(reader.recognises(URL(string: "https://www.mixcloud.com/some-dj/some-show/")!))
        #expect(!reader.recognises(URL(string: "https://www.mixcloud.com/some-dj/")!))
        #expect(!reader.recognises(URL(string: "https://www.mixcloud.com/some-dj/playlists/")!))
        #expect(!reader.recognises(URL(string: "https://www.mixcloud.com/discover/jazz/")!))
    }
}
