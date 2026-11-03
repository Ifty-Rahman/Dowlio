import DowlioCore
import DowlioMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SnapchatReaderTests {
    private let snap = "/@samplecreator/spotlight/W7_SampleSnapIdOne000000000000000000000000000000000AAAAw"

    private func snapchat() async throws -> ReaderSite {
        try await ReaderSite { _ in SnapchatReader(hosts: ["127.0.0.1"]) }
    }

    @Test func aSpotlightSnapIsReadFromThePagesData() async throws {
        let site = try await snapchat()
        try site.serve(fixture: "snapchat-spotlight.html", at: snap)

        let candidates = try await site.candidates(snap)

        let video = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(video.label == "Sample Creator: He has war footage")
        #expect(video.thumbnail == URL(string: "https://cf-st.sc-cdn.example/d/SampleMediaOne.256.IRZXSOY?mo=signature&uc=46"))
        #expect(video.duration == 5.34)
        #expect(video.versions.map(\.height) == [540])
        #expect(video.versions.map(\.codecs) == ["H.264 + AAC"])
    }

    @Test func theSpotlightFeedListsEveryLoadedSnap() async throws {
        let site = try await snapchat()
        try site.serve(fixture: "snapchat-spotlight.html", at: "/spotlight")

        let candidates = try await site.candidates("/spotlight")

        #expect(candidates.map(\.versions.first?.source.url.lastPathComponent) == ["SampleMediaOne.27.IRZXSOY", "SampleMediaTwo.27.IRZXSOY"])
        #expect(candidates.last?.label == "He has war footage | Spotlight")
    }

    @Test func aSnapMissingFromThePageIsLoggedAsFindingNothing() async throws {
        let site = try await snapchat()
        try site.serve(fixture: "snapchat-spotlight.html", at: "/spotlight/W7_Missing")

        let found = try await site.site.analyze("/spotlight/W7_Missing")

        #expect(found == .found([]))
        #expect(site.log.failures == [ReaderFailure(reader: "Snapchat Spotlight", site: site.host, reason: "found nothing")])
    }

    @Test func snapchatRecognisesSpotlightPermalinks() {
        let reader = SnapchatReader()
        #expect(reader.recognises(URL(string: "https://www.snapchat.com/spotlight")!))
        #expect(!reader.recognises(URL(string: "https://www.snapchat.com/add/someone")!))
        #expect(reader.post(in: URL(string: "https://www.snapchat.com/@someone/spotlight/W7_EDlXWTBiXAEEniNoMPwAAYa2tnZXJieXNoAZ-WUTbFAZ-WUTXwAAAAAw")!) == "W7_EDlXWTBiXAEEniNoMPwAAYa2tnZXJieXNoAZ-WUTbFAZ-WUTXwAAAAAw")
        #expect(reader.post(in: URL(string: "https://www.snapchat.com/spotlight")!) == nil)
    }
}
