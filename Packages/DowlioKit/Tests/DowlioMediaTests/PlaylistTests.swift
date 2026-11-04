import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PlaylistTests {
    private func analyze(_ link: String, with standIn: YTDLPStandIn) async throws -> PageAnalysis {
        let analyzer = PageAnalyzer(readers: [], ytdlp: YTDLPRunner(installer: standIn.installer)) { _, _ in throw URLError(.cannotConnectToHost) }
        var last: PageAnalysis?
        for await update in analyzer.analyze(SentPage(url: URL(string: link)!)) { last = update }
        return try #require(last)
    }

    @Test func aPlaylistListsEveryVideoFlatWithItsTitleAndAvailability() async throws {
        let standIn = try await YTDLPStandIn.printing("playlist.json")

        let found = try await analyze("https://www.youtube.com/playlist?list=PLlaN88a7y2_plecYoJxvRFTLHVbIVAOoc", with: standIn)

        guard case .playlist(let playlist) = found else { Issue.record("not a playlist: \(found)"); return }
        #expect(playlist.title == "Rick Astley: Official Music Videos")
        #expect(playlist.entries.count == 20)
        #expect(playlist.entries.first?.title == "Rick Astley - Never Gonna Give You Up (Official Animated Video)")
        #expect(playlist.entries.first?.url == URL(string: "https://www.youtube.com/watch?v=LLFhKaqnWwk"))
        #expect(playlist.entries.map(\.position) == Array(1...20))
        #expect(playlist.entries.filter { !$0.isAvailable }.map(\.title) == ["[Private video]", "[Deleted video]"])
        #expect(!playlist.isMusic)
        #expect(!playlist.isCut)
        #expect(playlist.channel == "Rick Astley")
        #expect(playlist.thumbnail?.path() == "/vi/LLFhKaqnWwk/hqdefault.jpg")
        #expect(playlist.updated == DateComponents(calendar: .current, year: 2026, month: 10, day: 1).date)
        #expect(playlist.entries.first?.thumbnail?.path() == "/vi/LLFhKaqnWwk/hqdefault.jpg")
        #expect(standIn.arguments.contains("--flat-playlist"))
        #expect(!standIn.arguments.contains("--no-playlist"))
    }

    @Test(arguments: ["https://music.youtube.com/browse/MPREb_tQfaWH32ovE", "https://music.youtube.com/playlist?list=OLAK5uy_lqcFZTOPHGwcnP0nYMzNuY0IES0fl7Fe4"])
    func aYouTubeMusicAlbumIsAPlaylistThatOpensOnAudio(link: String) async throws {
        let standIn = try await YTDLPStandIn.printing("album.json")

        let found = try await analyze(link, with: standIn)

        guard case .playlist(let playlist) = found else { Issue.record("not a playlist: \(found)"); return }
        #expect(playlist.isMusic)
        #expect(playlist.entries.count == 40)
    }

    @Test func aPlaylistLongerThanAThousandVideosListsTheFirstThousand() async throws {
        let standIn = try await YTDLPStandIn.printing("derived-playlist-1203.json")

        let found = try await analyze("https://www.youtube.com/playlist?list=PLlaN88a7y2_plecYoJxvRFTLHVbIVAOoc", with: standIn)

        guard case .playlist(let playlist) = found else { Issue.record("not a playlist: \(found)"); return }
        #expect(playlist.entries.count == 1000)
        #expect(playlist.total == 1203)
        #expect(playlist.isCut)
        #expect(standIn.arguments.contains("1001"))
    }

    @Test func aWatchLinkInsideAPlaylistShowsThatVideoAndOffersTheWholePlaylist() async throws {
        let standIn = try await YTDLPStandIn.install(script: """
            case "$*" in
              *--flat-playlist*) cat '\(YTDLPStandIn.fixture("playlist.json").path)' ;;
              *) cat '\(YTDLPStandIn.fixture("video-1080p.json").path)' ;;
            esac
            """)

        let found = try await analyze("https://www.youtube.com/watch?v=2Vv-BfVoq4g&list=PLlaN88a7y2_plecYoJxvRFTLHVbIVAOoc&index=3", with: standIn)

        guard case .found(let candidates) = found, let video = candidates.first else { Issue.record("not found: \(found)"); return }
        #expect(video.label == "Ed Sheeran - Perfect (Official Music Video)")
        #expect(!video.versions.isEmpty)
        #expect(video.playlistOffer?.count == 18)
        #expect(video.playlistOffer?.url == URL(string: "https://www.youtube.com/playlist?list=PLlaN88a7y2_plecYoJxvRFTLHVbIVAOoc"))
    }

    @Test(arguments: ["https://www.youtube.com/watch?v=2Vv-BfVoq4g&list=RD2Vv-BfVoq4g", "https://www.youtube.com/watch?v=2Vv-BfVoq4g&list=WL"])
    func aMixOrPersonalListIsTreatedAsJustTheVideo(link: String) {
        #expect(YouTubeLink(URL(string: link)!)?.kind == .video)
    }

    @Test func aVideoInAPlaylistTwiceGetsTwoEntries() {
        let url = URL(string: "https://www.youtube.com/watch?v=x")!
        let first = PlaylistListing.Entry(id: "x", position: 1, title: "X", url: url)
        let second = PlaylistListing.Entry(id: "x", position: 5, title: "X", url: url)

        #expect(first.id != second.id)
    }

    @Test(arguments: [
        "https://www.youtube.com/@RickAstleyYT",
        "https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw",
        "https://www.youtube.com/c/RickAstley/videos",
        "https://www.youtube.com/user/RickAstleyVEVO",
    ])
    func aChannelIsRefused(link: String) async throws {
        let standIn = try await YTDLPStandIn.printing("playlist.json")

        let found = try await analyze(link, with: standIn)

        #expect(found == .ytdlpFailed(.channel))
        #expect(standIn.runs == 0)
    }
}
