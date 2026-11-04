import DowlioCore
import DowlioLibrary
import DowlioStore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MediaSourceTests {
    private let media = try! MediaSource(tracks: [
        MediaTrack(kind: .video, fragments: [MediaFragment(url: URL(string: "https://cdn.example/clip/video.mp4")!)]),
        MediaTrack(kind: .audio, fragments: [MediaFragment(url: URL(string: "https://cdn.example/clip/audio.m4a")!)]),
    ])

    @Test func aMediaDownloadIsKeptAsMediaAcrossARelaunch() async throws {
        let fixture = try await LibraryFixture()
        let id = await fixture.library.add(
            .media(media), destination: .folder(fixture.folder), options: RequestOptions(), startImmediately: false
        )

        let relaunched = try await fixture.relaunched()
        let restored = try await relaunched.library.row(id) { _ in true }
        await relaunched.library.resume(id)
        let failed = try await relaunched.library.row(id) { $0.hasEnded }

        #expect(restored.state == .paused)
        #expect(restored.sourceURL == URL(string: "https://cdn.example/clip/video.mp4"))
        #expect(failed.host == "cdn.example")
    }

    @Test func historyKeepsAMediaDownloadsContainerExpiryRenewalAndRequestSizeLimit() async throws {
        let expiry = Date(timeIntervalSince1970: 1_793_799_948)
        let renewable = try MediaSource(
            tracks: media.tracks, container: .webm, expiry: expiry,
            renewal: MediaRenewal(pageURL: URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!, formatIDs: ["315", "251"])
        )
        var options = RequestOptions()
        options.requestSizeLimit = 10_485_760
        let fixture = try await LibraryFixture()
        let id = await fixture.library.add(
            .media(renewable), destination: .folder(fixture.folder), options: options, startImmediately: false
        )
        _ = try await fixture.library.row(id) { _ in true }

        let stored = try DownloadStore(databaseAt: fixture.databaseURL).all().first { $0.id == id.rawValue }

        #expect(stored?.source == .media(renewable))
        #expect(stored?.mediaSource?.container == .webm)
        #expect(stored?.mediaSource?.expiry == expiry)
        #expect(stored?.mediaSource?.renewal?.formatIDs == ["315", "251"])
        #expect(stored?.options.requestSizeLimit == 10_485_760)
    }

    @Test func aMediaSourceSavedBeforePhaseSixReadsWithNoContainerExpiryOrRenewal() throws {
        let saved = Data(#"{"tracks":[{"kind":"video","fragments":[{"url":"https://cdn.example/v.mp4"}]}],"keepsAudioOnly":false}"#.utf8)

        let read = try JSONDecoder().decode(MediaSource.self, from: saved)

        #expect(read.container == nil)
        #expect(read.expiry == nil)
        #expect(read.renewal == nil)
        #expect(read.fileExtension == "mp4")
    }

    @Test func retryingAFailedMediaDownloadDoesntHoldADownloadSlot() async throws {
        let fixture = try await LibraryFixture()
        await fixture.library.setMaximumActive(1)
        let id = await fixture.library.add(.media(media), destination: .folder(fixture.folder))
        _ = try await fixture.library.row(id) { $0.hasEnded }

        await fixture.library.retry(id)
        let next = await fixture.add(URL(string: "http://127.0.0.1:9/next.bin")!)
        let row = try await fixture.library.row(next) { $0.state != .queued }

        #expect(row.state != .queued)
    }
}
