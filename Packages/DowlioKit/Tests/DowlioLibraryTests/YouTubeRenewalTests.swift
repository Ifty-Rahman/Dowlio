import AVFoundation
import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioStore
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YouTubeRenewalTests {
    private static let page = URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!
    private static let limit: Int64 = 4096

    private struct Clip {
        let server: TestServer
        let video: Data
        let audio: Data

        func media(at folder: String, audio audioName: String = "audio", audioData: Data? = nil, expiry: Date?) throws -> MediaSource {
            let sound = audioData ?? audio
            return try MediaSource(
                tracks: [
                    MediaTrack(kind: .video, fragments: [MediaFragment(url: server.url(for: "/\(folder)/video"), bytes: 0...Int64(video.count - 1))], codecs: ["avc1.64000c"]),
                    MediaTrack(kind: .audio, fragments: [MediaFragment(url: server.url(for: "/\(folder)/\(audioName)"), bytes: 0...Int64(sound.count - 1))], codecs: ["mp4a.40.2"]),
                ],
                container: .mp4, expiry: expiry, renewal: MediaRenewal(pageURL: YouTubeRenewalTests.page, formatIDs: ["137", "140"])
            )
        }

        func serve(at folder: String, video file: TestServer.File? = nil, audio audioFile: TestServer.File? = nil, audioName: String = "audio") {
            server.serve(file ?? TestServer.File(data: video), at: "/\(folder)/video")
            server.serve(audioFile ?? TestServer.File(data: audio), at: "/\(folder)/\(audioName)")
        }

        func requests(to path: String) -> Int {
            server.requests.filter { $0.path == path }.count
        }
    }

    private func clip() async throws -> Clip {
        Clip(server: try await TestServer(), video: try TestMedia.data("track-h264.mp4"), audio: try TestMedia.data("track-aac.m4a"))
    }

    private func options() -> RequestOptions {
        var options = RequestOptions()
        options.fileName = "Perfect.mp4"
        options.connections = 4
        options.requestSizeLimit = Self.limit
        return options
    }

    private static func pieces(_ data: Data) -> Int {
        Int((Int64(data.count) + limit - 1) / limit)
    }

    @Test func anExpiredLinkIsRenewedBeforeAnyRequest() async throws {
        let clip = try await clip()
        clip.serve(at: "fresh")
        let renewals = Counter()
        let fresh = try clip.media(at: "fresh", expiry: Date().addingTimeInterval(6 * 60 * 60))
        let fixture = try await LibraryFixture(renew: { old in
            renewals.add()
            #expect(old.renewal?.formatIDs == ["137", "140"])
            return fresh
        })

        let stale = try clip.media(at: "stale", expiry: Date().addingTimeInterval(-60))
        let id = await fixture.library.add(.media(stale), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(renewals.count == 1)
        #expect(!clip.server.requests.contains { $0.path.hasPrefix("/stale/") })
    }

    @Test func aLinkThatStillHasTimeIsntRenewed() async throws {
        let clip = try await clip()
        clip.serve(at: "current")
        let renewals = Counter()
        let fixture = try await LibraryFixture(renew: { old in
            renewals.add()
            return old
        })

        let media = try clip.media(at: "current", expiry: Date().addingTimeInterval(60 * 60))
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(renewals.count == 0)
    }

    @Test func aLinkNearItsExpiryStillDownloadsWhenRenewalFails() async throws {
        let clip = try await clip()
        clip.serve(at: "current")
        let fixture = try await LibraryFixture(renew: { _ in throw RenewalFailure.failed })

        let media = try clip.media(at: "current", expiry: Date().addingTimeInterval(60))
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
    }

    @Test func aLinkThatDiesAfterAnUpFrontRenewalIsRenewedAgain() async throws {
        let clip = try await clip()
        clip.serve(at: "first", video: TestServer.File(data: clip.video, forbiddenAfterRequests: 2))
        clip.serve(at: "second")
        let renewals = Counter()
        let fixture = try await LibraryFixture(renew: { _ in
            renewals.add()
            return try clip.media(at: renewals.count == 1 ? "first" : "second", expiry: Date().addingTimeInterval(6 * 60 * 60))
        })

        let stale = try clip.media(at: "stale", expiry: Date().addingTimeInterval(-60))
        let id = await fixture.library.add(.media(stale), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(renewals.count == 2)
    }

    @Test func a403MidDownloadRenewsAndKeepsThePiecesItHasWhenTheSizeMatches() async throws {
        let clip = try await clip()
        clip.serve(at: "stale", video: TestServer.File(data: clip.video, forbiddenAfterRequests: 3))
        clip.serve(at: "fresh")
        let fixture = try await LibraryFixture(renew: { _ in try clip.media(at: "fresh", expiry: Date().addingTimeInterval(6 * 60 * 60)) })

        let media = try clip.media(at: "stale", expiry: Date().addingTimeInterval(6 * 60 * 60))
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(((Self.pieces(clip.video) - 3)...(Self.pieces(clip.video) - 1)).contains(clip.requests(to: "/fresh/video")))
        let asset = AVURLAsset(url: fixture.folder.appending(path: "Perfect.mp4"))
        #expect(Set(try await asset.load(.tracks).map(\.mediaType)) == [.video, .audio])
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.3)
    }

    @Test func freshFormatsOfADifferentSizeStartOverCleanly() async throws {
        let clip = try await clip()
        let longer = try TestMedia.data("track-aac-4s.m4a")
        clip.serve(at: "stale", audio: TestServer.File(data: clip.audio, forbiddenAfterRequests: 2))
        clip.serve(at: "fresh", audio: TestServer.File(data: longer), audioName: "longer")
        let fixture = try await LibraryFixture(renew: { _ in
            try clip.media(at: "fresh", audio: "longer", audioData: longer, expiry: Date().addingTimeInterval(6 * 60 * 60))
        })

        let media = try clip.media(at: "stale", expiry: Date().addingTimeInterval(6 * 60 * 60))
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(clip.requests(to: "/fresh/video") == Self.pieces(clip.video))
        #expect(clip.requests(to: "/fresh/longer") == Self.pieces(longer))
        let asset = AVURLAsset(url: fixture.folder.appending(path: "Perfect.mp4"))
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await audio.load(.timeRange).duration.seconds - 4) < 0.3)
    }

    @Test func historyKeepsThePageAndFormatsAndTheRenewedLinksButNoCookies() async throws {
        let clip = try await clip()
        clip.serve(at: "fresh")
        let fixture = try await LibraryFixture(renew: { _ in try clip.media(at: "fresh", expiry: Date().addingTimeInterval(6 * 60 * 60)) })
        var options = options()
        options.cookies = [Cookie(name: "SID", value: "secret-session-value", domain: ".youtube.com")]

        let stale = try clip.media(at: "stale", expiry: Date().addingTimeInterval(-60))
        let id = await fixture.library.add(.media(stale), destination: .folder(fixture.folder), options: options)
        _ = try await fixture.library.row(id) { $0.hasEnded }

        let stored = try #require(try DownloadStore(databaseAt: fixture.databaseURL).all().first { $0.id == id.rawValue })
        #expect(stored.mediaSource?.renewal == MediaRenewal(pageURL: Self.page, formatIDs: ["137", "140"]))
        #expect(stored.mediaSource?.tracks.first?.fragments.first?.url.path() == "/fresh/video")
        #expect(try Data(contentsOf: fixture.databaseURL).range(of: Data("secret-session-value".utf8)) == nil)
    }

    @Test func withTheToolsRemovedRenewalFailsAskingForThem() async throws {
        let clip = try await clip()
        let fixture = try await LibraryFixture(renew: { _ in throw RenewalFailure.toolsMissing })

        let stale = try clip.media(at: "stale", expiry: Date().addingTimeInterval(-60))
        let id = await fixture.library.add(.media(stale), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .failed(.needsTools))
        #expect(FailureText(.needsTools, isMedia: true).reason == "Needs yt-dlp")
    }

    @Test func aPausedDownloadRenewsAfterARestartWhenItsOldLinkIsGone() async throws {
        let clip = try await clip()
        clip.serve(at: "stale", video: TestServer.File(data: clip.video, holdAfterBytes: 0), audio: TestServer.File(data: clip.audio, holdAfterBytes: 0))
        clip.serve(at: "fresh")
        let renew: @Sendable (MediaSource) async throws -> MediaSource = { _ in try clip.media(at: "fresh", expiry: Date().addingTimeInterval(6 * 60 * 60)) }
        let fixture = try await LibraryFixture(renew: renew)
        let media = try clip.media(at: "stale", expiry: Date().addingTimeInterval(6 * 60 * 60))
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder), options: options())
        try await waitUntil { clip.server.openConnections(at: "/stale/video") > 0 }
        await fixture.library.pause(id)
        _ = try await fixture.library.row(id) { $0.state == .paused }

        clip.server.remove("/stale/video")
        clip.server.remove("/stale/audio")
        clip.server.releaseHeldResponses()
        let relaunched = try await fixture.relaunched()
        await relaunched.library.resume(id)
        let row = try await relaunched.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(clip.requests(to: "/fresh/video") > 0)
    }
}
