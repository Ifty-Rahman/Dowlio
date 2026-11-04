import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YTDLPRenewalTests {
    private let page = URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!

    private func stale(_ ids: [String], container: MediaContainer = .mp4) throws -> MediaSource {
        let old = URL(string: "https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=old")!
        let tracks = ids.enumerated().map { index, _ in MediaTrack(kind: index == 0 && ids.count > 1 ? .video : .audio, fragments: [MediaFragment(url: old, bytes: 0...9)]) }
        return try MediaSource(tracks: tracks, container: container, expiry: Date(timeIntervalSince1970: 0), renewal: MediaRenewal(pageURL: page, formatIDs: ids))
    }

    @Test func freshLinksAreForTheSameFormats() async throws {
        let standIn = try await YTDLPStandIn.printing("video-1080p.json")
        let runner = YTDLPRunner(installer: standIn.installer)

        let fresh = try await runner.renew(try stale(["137", "140"]))

        #expect(fresh.tracks.map { $0.fragments.first?.url.query()?.contains("itag=137") == true } == [true, false])
        #expect(fresh.tracks[1].fragments.first?.url.query()?.contains("itag=140") == true)
        #expect(fresh.tracks.map(\.kind) == [.video, .audio])
        #expect(fresh.tracks.map { $0.fragments.map(\.bytes) } == [[0...77_615_174], [0...4_562_921]])
        #expect(fresh.expiry == Date(timeIntervalSince1970: 1_793_799_947))
        #expect(fresh.renewal == MediaRenewal(pageURL: page, formatIDs: ["137", "140"]))
        #expect(fresh.container == .mp4)
        #expect(!standIn.arguments.contains { $0.hasPrefix("--cookies") })
    }

    @Test func withTheToolsRemovedRenewalSaysTheyAreMissing() async throws {
        let standIn = try await YTDLPStandIn.notInstalled()
        let runner = YTDLPRunner(installer: standIn.installer)

        await #expect(throws: RenewalFailure.toolsMissing) { try await runner.renew(try stale(["137", "140"])) }
    }

    @Test func aFormatThatIsGoneFailsRenewal() async throws {
        let standIn = try await YTDLPStandIn.printing("video-1080p.json")
        let runner = YTDLPRunner(installer: standIn.installer)

        await #expect(throws: RenewalFailure.failed) { try await runner.renew(try stale(["999", "140"])) }
    }

    @Test func renewalRetriesOnceWithTheBrowsersSignInWhenTheVideoNeedsIt() async throws {
        let standIn = try await YTDLPStandIn.install(script: """
            case "$*" in
              *--cookies*) cat '\(YTDLPStandIn.fixture("video-1080p.json").path)'; exit 0 ;;
            esac
            cat '\(YTDLPStandIn.errorText("needsSignIn").path)' >&2
            exit 1
            """)
        let runner = YTDLPRunner(installer: standIn.installer)
        let cookies = [Cookie(name: "SID", value: "x", domain: ".youtube.com")]

        let fresh = try await runner.renew(try stale(["137", "140"]), signIn: { _ in cookies })

        #expect(fresh.tracks.count == 2)
        #expect(standIn.runs == 2)
    }
}
