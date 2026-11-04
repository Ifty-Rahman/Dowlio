import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PlaylistEntryListingTests {
    private let page = URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!

    private func entry(_ choice: MediaRenewal.Choice) throws -> MediaSource {
        try MediaSource(
            tracks: [MediaTrack(kind: choice.audioOnly ? .audio : .combined, fragments: [MediaFragment(url: page)])],
            container: choice.audioOnly ? .m4a : .mp4,
            renewal: MediaRenewal(pageURL: page, formatIDs: [], choice: choice)
        )
    }

    private func listed(_ fixture: String, _ choice: MediaRenewal.Choice) async throws -> MediaSource {
        let standIn = try await YTDLPStandIn.printing(fixture)
        return try await YTDLPRunner(installer: standIn.installer).renew(try entry(choice), decodesAV1: true)
    }

    @Test func anEntryTakesTheChosenHeight() async throws {
        let source = try await listed("video-1080p.json", MediaRenewal.Choice(tallest: 720))

        #expect(source.renewal?.formatIDs == ["136", "140"])
        #expect(source.renewal?.pageURL == page)
        #expect(source.outputContainer == .mp4)
    }

    @Test func anEntryWithoutTheChosenHeightTakesTheNextLowerOne() async throws {
        let higher = try await listed("video-1080p.json", MediaRenewal.Choice(tallest: 1440))
        let lowest = try await listed("video-1080p.json", MediaRenewal.Choice(tallest: 100))

        #expect(higher.renewal?.formatIDs == ["137", "140"])
        #expect(lowest.renewal?.formatIDs == ["160", "140"])
    }

    @Test func audioOnlyTakesTheOriginalAudioWithCoverArtAndNoSubtitles() async throws {
        let source = try await listed("video-subtitles-chapters.json", MediaRenewal.Choice(audioOnly: true, subtitleLanguages: ["en"]))

        #expect(source.isAudio)
        #expect(source.outputContainer == .m4a)
        #expect(source.extras?.coverArt != nil)
        #expect(source.extras?.subtitles.isEmpty ?? true)
    }

    @Test func anEntryGetsTheSubtitlesChosenForThePlaylist() async throws {
        let source = try await listed("video-subtitles-chapters.json", MediaRenewal.Choice(tallest: 720, subtitleLanguages: ["en"]))

        #expect(source.extras?.subtitles.map(\.language) == ["en"])
        #expect(source.extras?.chapters.count == 22)
    }

    @Test func aPrivateEntryFailsWithItsOwnReason() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "private")

        await #expect(throws: DownloadError.needsSignIn) {
            try await YTDLPRunner(installer: standIn.installer).renew(try entry(MediaRenewal.Choice()), decodesAV1: true)
        }
    }
}
