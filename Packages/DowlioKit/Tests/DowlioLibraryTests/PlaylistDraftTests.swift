import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

@MainActor
struct PlaylistDraftTests {
    private func listing(available: Int, unavailable: Int = 0, isMusic: Bool = false, total: Int? = nil, isCut: Bool = false) -> PlaylistListing {
        let entries = (0..<(available + unavailable)).map { index in
            PlaylistListing.Entry(
                id: "v\(index)", position: index + 1, title: index < available ? "Video \(index + 1)" : "[Private video]",
                url: URL(string: "https://www.youtube.com/watch?v=v\(index)")!, isAvailable: index < available
            )
        }
        return PlaylistListing(
            title: "Mix", url: URL(string: "https://www.youtube.com/playlist?list=PL1")!, entries: entries,
            total: total ?? entries.count, isMusic: isMusic, isCut: isCut
        )
    }

    private func draft(_ listing: PlaylistListing, quality: VideoQuality = .best) -> SentPageDraft {
        var draft = SentPageDraft(page: SentPage(url: listing.url), preference: QualityPreference(quality: quality))
        _ = draft.update(.playlist(listing))
        return draft
    }

    @Test func everyAvailableVideoIsIncludedAndUnavailableOnesAreLeftOut() {
        var draft = draft(listing(available: 18, unavailable: 2))

        #expect(draft.phase == .playlist)
        #expect(draft.includedEntries.count == 18)
        #expect(draft.playlistLine == "18 of 18 videos")
        let privateOne = try! #require(draft.playlist?.entries.last)
        draft.include(privateOne, true)
        #expect(!draft.isIncluded(privateOne))

        draft.include(try! #require(draft.playlist?.entries.first), false)
        #expect(draft.playlistLine == "17 of 18 videos")
    }

    @Test func onePlaylistWideChoiceStartsFromTheQualitySettingAndAudioForMusic() {
        var video = draft(listing(available: 3), quality: .upTo(720))
        let music = draft(listing(available: 3, isMusic: true))

        #expect(video.playlistShowing == .video)
        #expect(video.playlistQuality == .upTo(720))
        #expect(music.playlistShowing == .audio)

        video.choosePlaylist(.video, quality: .upTo(1080))
        #expect(video.playlistQuality == .upTo(1080))
        video.choosePlaylist(.audio)
        #expect(video.playlistShowing == .audio)
    }

    @Test func aCutPlaylistSaysSo() {
        let cut = draft(listing(available: 1000, total: 1203, isCut: true))
        let whole = draft(listing(available: 20, total: 43))

        #expect(cut.playlistNote == "This playlist has 1,203 videos. Dowlio lists the first 1,000.")
        #expect(whole.playlistNote == nil)
    }

    @Test func aWatchLinkInAPlaylistOffersTheWholePlaylist() async throws {
        var video = Candidate(label: "Perfect", versions: [])
        video.playlistOffer = PlaylistOffer(url: URL(string: "https://www.youtube.com/playlist?list=PL1")!, count: 18)
        let playlist = listing(available: 18)
        let list = LinkList(analyze: { page in
            page.url.path() == "/playlist" ? .once(.playlist(playlist)) : .once(.found([video]))
        })
        list.send(SentPage(url: URL(string: "https://www.youtube.com/watch?v=x&list=PL1")!))
        try await waitForPage(list) { $0.draft.phase == .found }
        let model = try #require(page(of: list))

        #expect(model.draft.wholePlaylistLine == "Whole playlist (18 videos)")
        model.showWholePlaylist()
        try await waitForPage(list) { $0.draft.phase == .playlist }

        #expect(model.draft.includedEntries.count == 18)
    }

    @Test func aChannelSaysChannelsArentSupported() {
        var draft = SentPageDraft(page: SentPage(url: URL(string: "https://www.youtube.com/@x")!))

        _ = draft.update(.ytdlpFailed(.channel))

        #expect(draft.problem?.sentence == "Channels aren't supported.")
    }
}

@MainActor
private func page(of list: LinkList) -> SentPageModel? {
    switch list.items.first?.kind {
    case .page(let page)?, .video(let page, _)?: page
    default: nil
    }
}

@MainActor
private func waitForPage(_ list: LinkList, _ condition: (SentPageModel) -> Bool) async throws {
    while !(page(of: list).map(condition) ?? false) { try await Task.sleep(for: .milliseconds(10)) }
}
