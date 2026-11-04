import DowlioCore
import DowlioLibrary
import DowlioMedia
import DowlioStore
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YTDLPDownloadTests {
    private static let page = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!

    private static func script(pauseAfterFirstHalf: Bool = false) -> String {
        """
        out=""
        previous=""
        for argument in "$@"; do
          if [ "$previous" = "-o" ]; then out="$argument"; fi
          previous="$argument"
        done
        final=$(echo "$out" | sed 's/%(ext)s/mp4/')
        part="$final.part"
        if [ ! -f "$part" ]; then
          printf 'first-half-' > "$part"
          echo "dowlio-progress 400+140 1000 4000 NA 2000 1.5"
          echo "dowlio-progress 400+140 2000 4000 NA 2000 1.0"
          \(pauseAfterFirstHalf ? "sleep 30" : "")
        fi
        printf 'leftover' > "$(dirname "$final")/media.f400.mp4"
        printf 'second-half' >> "$part"
        echo "dowlio-progress 400+140 3000 4000 NA 2000 0.5"
        echo "dowlio-progress 400+140 4000 4000 NA 2000 0"
        mv "$part" "$final"
        """
    }

    private func fallback(audioOnly: Bool = false) throws -> MediaSource {
        try MediaSource(
            tracks: [MediaTrack(kind: .combined, fragments: [MediaFragment(url: Self.page)])],
            container: .mp4,
            renewal: MediaRenewal(pageURL: Self.page, formatIDs: ["400", "140"]),
            downloadsWithYTDLP: true
        )
    }

    private func fixture(_ standIn: YTDLPStandIn) async throws -> LibraryFixture {
        let runner = YTDLPRunner(installer: standIn.installer, ffmpeg: TestFFmpeg.helper)
        return try await LibraryFixture(downloadWithYTDLP: { request in try await runner.download(request) })
    }

    private func options() -> RequestOptions {
        var options = RequestOptions()
        options.fileName = "Big Buck Bunny.mp4"
        return options
    }

    @Test func aVersionNoOtherPathCanReachIsDownloadedByYTDLPWithItsProgress() async throws {
        let standIn = try await YTDLPStandIn.install(script: Self.script())
        let fixture = try await fixture(standIn)

        let id = await fixture.library.add(.media(try fallback()), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(row.fileName == "Big Buck Bunny.mp4")
        let file = fixture.folder.appending(path: "Big Buck Bunny.mp4")
        #expect(try String(contentsOf: file, encoding: .utf8) == "first-half-second-half")
        let arguments = standIn.arguments
        #expect(arguments.contains("400+140"))
        #expect(arguments.contains("--newline"))
        #expect(arguments.contains("--merge-output-format"))
        #expect(arguments.last == Self.page.absoluteString)
        if let helper = TestFFmpeg.helper { #expect(arguments.contains(helper.path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path) == ["Big Buck Bunny.mp4"])
    }

    @Test func progressLinesBecomeTheRowsProgressSpeedAndTimeLeft() async throws {
        let standIn = try await YTDLPStandIn.install(script: Self.script(pauseAfterFirstHalf: true))
        let fixture = try await fixture(standIn)

        let id = await fixture.library.add(.media(try fallback()), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.receivedBytes == 2000 }

        #expect(row.bytesPerSecond == 2000)
        #expect(row.timeRemaining == 1.0)
        await fixture.library.cancel(id)
    }

    @Test func progressAcrossTwoFormatsAddsUpBothParts() async throws {
        let standIn = try await YTDLPStandIn.install(script: """
            echo "dowlio-progress 400 4000 4000 NA 2000 3"
            echo "dowlio-progress 140 1000 2000 NA 2000 1"
            sleep 30
            """)
        let fixture = try await fixture(standIn)

        let id = await fixture.library.add(.media(try fallback()), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.receivedBytes == 5000 }

        #expect(row.totalBytes == 6000)
        await fixture.library.cancel(id)
    }

    @Test func pauseStopsYTDLPAndResumeContinuesItsOwnPartialFile() async throws {
        let standIn = try await YTDLPStandIn.install(script: Self.script(pauseAfterFirstHalf: true))
        let fixture = try await fixture(standIn)
        let id = await fixture.library.add(.media(try fallback()), destination: .folder(fixture.folder), options: options())
        _ = try await fixture.library.row(id) { $0.receivedBytes == 2000 }

        await fixture.library.pause(id)
        _ = try await fixture.library.row(id) { $0.state == .paused }
        await fixture.library.resume(id)
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .completed)
        #expect(standIn.runs == 2)
        let file = fixture.folder.appending(path: "Big Buck Bunny.mp4")
        #expect(try String(contentsOf: file, encoding: .utf8) == "first-half-second-half")
    }

    @Test func cancelStopsYTDLPAndDeletesItsFiles() async throws {
        let standIn = try await YTDLPStandIn.install(script: Self.script(pauseAfterFirstHalf: true))
        let fixture = try await fixture(standIn)
        let id = await fixture.library.add(.media(try fallback()), destination: .folder(fixture.folder), options: options())
        _ = try await fixture.library.row(id) { $0.receivedBytes == 2000 }

        await fixture.library.cancel(id)
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: fixture.folder.path))?.isEmpty == true }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty)
    }

    @Test func aYTDLPDownloadThatNeedsSignInFailsAsNeedsSignIn() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "needsSignIn")
        let fixture = try await fixture(standIn)

        let id = await fixture.library.add(.media(try fallback()), destination: .folder(fixture.folder), options: options())
        let row = try await fixture.library.row(id) { $0.hasEnded }

        #expect(row.state == .failed(.needsSignIn))
    }
}
