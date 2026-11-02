import DowlioCore
import DowlioLibrary
import DowlioMedia
import Foundation
import Testing

struct AudioOnlyCandidateTests {
    private let page = SentPage(url: URL(string: "https://artist.bandcamp.com/track/song")!)
    private let mp3 = Version(source: .file(URL(string: "https://cdn.example.com/song.mp3")!), contentType: "audio/mpeg", totalBytes: 3_000_000, codecs: "MP3")

    @Test func aTrackWithOnlyAudioVersionsDefaultsToAudioAndOffersNoVideoToggle() {
        var draft = SentPageDraft(page: page)
        _ = draft.update(.found([Candidate(label: "Song", versions: [mp3])]))

        #expect(draft.chosenVersion == mp3)
        #expect(!draft.hasVideoAndAudio)
        #expect(draft.selectedCandidate?.versions.contains { $0.isExtractedAudio } == false)
    }

    @Test func aPreferenceForVideoDoesNotHideAnAudioOnlyTracksVersion() {
        var draft = SentPageDraft(page: page, preference: QualityPreference(quality: .upTo(720)))
        _ = draft.update(.found([Candidate(label: "Song", versions: [mp3])]))

        draft.show(.video)

        #expect(draft.chosenVersion == mp3)
    }
}
