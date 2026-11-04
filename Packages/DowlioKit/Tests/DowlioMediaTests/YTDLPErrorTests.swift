import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YTDLPErrorTests {
    private let watch = URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!
    private let signedIn = [Cookie(name: "SID", value: "secret-session", domain: ".youtube.com", path: "/", secure: true)]

    private let cookieFolder = try! TestFiles.makeFolder().appending(path: "Cookies", directoryHint: .isDirectory)

    private var cookieFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: cookieFolder.path)) ?? []
    }

    private func analyze(_ page: SentPage, with standIn: YTDLPStandIn, timeout: Duration = .seconds(30)) async throws -> PageAnalysis {
        let runner = YTDLPRunner(installer: standIn.installer, timeout: timeout, cookieFolder: cookieFolder)
        let analyzer = PageAnalyzer(readers: [], ytdlp: runner) { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        var last: PageAnalysis?
        for await update in analyzer.analyze(page) { last = update }
        return try #require(last)
    }

    @Test(arguments: [
        ("unsupportedSite", PageAnalysis.ytdlpFailed(.unsupportedSite)),
        ("needsSignIn", .needsSignIn),
        ("private", .ytdlpFailed(.private)),
        ("geoBlocked", .ytdlpFailed(.geoBlocked)),
        ("rateLimited", .ytdlpFailed(.rateLimited)),
        ("rateLimited-http429", .ytdlpFailed(.rateLimited)),
        ("rateLimited-bot", .ytdlpFailed(.rateLimited)),
        ("extractorBroken", .ytdlpFailed(.extractorBroken)),
        ("network", .ytdlpFailed(.network)),
        ("network-offline", .ytdlpFailed(.network)),
        ("live-upcoming", .ytdlpFailed(.live)),
        ("unavailable", .ytdlpFailed(.unavailable)),
    ])
    func eachFailureMapsToItsState(fixture: String, expected: PageAnalysis) async throws {
        let standIn = try await YTDLPStandIn.failing(with: fixture)

        #expect(try await analyze(SentPage(url: watch), with: standIn) == expected)
    }

    @Test func aBrokenSiteChecksForAnUpdateFirstAndRunsTheNewYTDLPOnce() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "extractorBroken")
        try standIn.publishUpdate(script: "cat '\(YTDLPStandIn.fixture("video-1080p.json").path)'")

        let found = try await analyze(SentPage(url: watch), with: standIn)

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.first?.versions.isEmpty == false)
        #expect(standIn.runs == 2)
        #expect(await standIn.installer.installedVersions()[.ytdlp] == "2026.11.03")
    }

    @Test func aBrokenSiteWithNoUpdateShowsTheErrorAfterOneRun() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "extractorBroken")

        #expect(try await analyze(SentPage(url: watch), with: standIn) == .ytdlpFailed(.extractorBroken))
        #expect(standIn.runs == 1)
    }

    @Test func aBrokenSiteThatStaysBrokenAfterTheUpdateShowsTheError() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "extractorBroken")
        try standIn.publishUpdate(script: "cat '\(YTDLPStandIn.errorText("extractorBroken").path)' >&2\nexit 1")

        #expect(try await analyze(SentPage(url: watch), with: standIn) == .ytdlpFailed(.extractorBroken))
        #expect(standIn.runs == 2)
    }

    @Test func aProtectedVideoUsesTheProtectedState() async throws {
        let standIn = try await YTDLPStandIn.failing(with: "protected")

        let found = try await analyze(SentPage(url: watch, title: "A film"), with: standIn)

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.map(\.restriction) == [.protected])
        #expect(candidates.first?.versions.isEmpty == true)
    }

    @Test func aStreamThatIsLiveDownloadsNothing() async throws {
        let standIn = try await YTDLPStandIn.printing("live.json")

        #expect(try await analyze(SentPage(url: watch), with: standIn) == .ytdlpFailed(.live))
    }

    @Test func aFinishedLiveStreamListsItsVersions() async throws {
        let standIn = try await YTDLPStandIn.printing("finished-live.json")

        let found = try await analyze(SentPage(url: watch), with: standIn)

        guard case .found(let candidates) = found, let video = candidates.first else { Issue.record("not found: \(found)"); return }
        #expect(video.versions.contains { $0.height == 1080 })
    }

    @Test func aRunPastItsTimeoutIsANetworkFailure() async throws {
        let standIn = try await YTDLPStandIn.install(script: "exec sleep 30")

        #expect(try await analyze(SentPage(url: watch), with: standIn, timeout: .milliseconds(400)) == .ytdlpFailed(.network))
    }

    private static func signInScript(for fixture: String, log: String) -> String {
        """
        cookies=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--cookies" ]; then cookies="$2"; fi
          shift
        done
        if [ -n "$cookies" ] && [ -f "$cookies" ]; then
          echo "$cookies" > '\(log)/cookie-path'
          ls -l "$cookies" | cut -c1-10 > '\(log)/cookie-mode'
          cat "$cookies" > '\(log)/cookie-contents'
          cat '\(YTDLPStandIn.fixture(fixture).path)'
          exit 0
        fi
        cat '\(YTDLPStandIn.errorText("needsSignIn").path)' >&2
        exit 1
        """
    }

    private func signInStandIn(log: URL, fixture: String = "video-1080p.json", after success: String = "") async throws -> YTDLPStandIn {
        try await YTDLPStandIn.install(script: Self.signInScript(for: fixture, log: log.path) + success)
    }

    @Test func aVideoThatNeedsSignInIsRetriedOnceWithTheBrowsersSignInThroughAPrivateCookieFile() async throws {
        let log = try TestFiles.makeFolder()
        let standIn = try await signInStandIn(log: log)

        let found = try await analyze(SentPage(url: watch, cookies: signedIn), with: standIn)

        guard case .found(let candidates) = found else { Issue.record("not found: \(found)"); return }
        #expect(candidates.first?.versions.isEmpty == false)
        #expect(standIn.runs == 2)
        let path = try String(contentsOf: log.appending(path: "cookie-path"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try String(contentsOf: log.appending(path: "cookie-mode"), encoding: .utf8).hasPrefix("-rw-------"))
        let contents = try String(contentsOf: log.appending(path: "cookie-contents"), encoding: .utf8)
        #expect(contents.hasPrefix("# Netscape HTTP Cookie File"))
        let cookie = try #require(contents.split(separator: "\n").first { $0.contains("SID") }).split(separator: "\t").map(String.init)
        #expect(cookie.count == 7)
        #expect(Array(cookie[1...3]) == ["TRUE", "/", "TRUE"])
        #expect(cookie[0].hasSuffix(".youtube.com"))
        #expect((Int(cookie[4]) ?? 0) > Int(Date().timeIntervalSince1970))
        #expect(Array(cookie[5...6]) == ["SID", "secret-session"])
    }

    @Test func aCookieValueCantBreakTheCookieFileIntoMoreLines() async throws {
        let log = try TestFiles.makeFolder()
        let standIn = try await signInStandIn(log: log)
        let sneaky = [Cookie(name: "SID", value: "a\rb\u{2028}c\nd", domain: ".youtube.com"), Cookie(name: "nodomain", value: "x")]

        _ = try await analyze(SentPage(url: watch, cookies: sneaky), with: standIn)

        let contents = try String(contentsOf: log.appending(path: "cookie-contents"), encoding: .utf8)
        #expect(contents.split(whereSeparator: \.isNewline).count == 2)
        #expect(contents.contains("SID\tabcd"))
        #expect(!contents.contains("nodomain"))
    }

    @Test func theFirstRunNeverPassesCookies() async throws {
        let log = try TestFiles.makeFolder()
        let standIn = try await signInStandIn(log: log)

        _ = try await analyze(SentPage(url: watch, cookies: signedIn), with: standIn)

        let firstRun = try String(contentsOf: standIn.log.appending(path: "all-arguments"), encoding: .utf8).components(separatedBy: "--run--")
        #expect(firstRun.count >= 2)
        #expect(!firstRun[1].contains("--cookies"))
    }

    @Test func withoutBrowserSignInThereIsNoRetry() async throws {
        let log = try TestFiles.makeFolder()
        let standIn = try await signInStandIn(log: log)

        let found = try await analyze(SentPage(url: watch), with: standIn)

        #expect(found == .needsSignIn)
        #expect(standIn.runs == 1)
    }

    @Test func aSignedInRetryThatStillFailsLeavesNoCookieFile() async throws {
        let standIn = try await YTDLPStandIn.install(script: """
            cat '\(YTDLPStandIn.errorText("private").path)' >&2
            exit 1
            """)

        let found = try await analyze(SentPage(url: watch, cookies: signedIn), with: standIn)

        #expect(found == .ytdlpFailed(.private))
        #expect(standIn.runs == 2)
        #expect(cookieFiles.isEmpty)
    }

    @Test func aSignedInRetryPastItsTimeoutLeavesNoCookieFile() async throws {
        let standIn = try await YTDLPStandIn.install(script: """
            case "$*" in
              *--cookies*) exec sleep 30 ;;
            esac
            cat '\(YTDLPStandIn.errorText("needsSignIn").path)' >&2
            exit 1
            """)

        _ = try await analyze(SentPage(url: watch, cookies: signedIn), with: standIn, timeout: .milliseconds(500))

        #expect(cookieFiles.isEmpty)
    }

    @Test func cancellingASignedInRetryLeavesNoCookieFile() async throws {
        let standIn = try await YTDLPStandIn.install(script: """
            case "$*" in
              *--cookies*) exec sleep 30 ;;
            esac
            cat '\(YTDLPStandIn.errorText("needsSignIn").path)' >&2
            exit 1
            """)
        let runner = YTDLPRunner(installer: standIn.installer, cookieFolder: cookieFolder)
        let analyzer = PageAnalyzer(readers: [], ytdlp: runner) { _, _ in throw URLError(.cannotConnectToHost) }
        let signedIn = signedIn
        let watch = watch
        let run = Task {
            for await _ in analyzer.analyze(SentPage(url: watch, cookies: signedIn)) {}
        }
        try await waitUntil { standIn.runs == 2 }
        let folder = cookieFolder
        try await waitUntil { !((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty }

        run.cancel()
        await run.value

        try await waitUntil { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty }
        #expect(cookieFiles.isEmpty)
    }

    @Test func leftoverCookieFilesAreDeletedAtLaunch() throws {
        let leftover = cookieFolder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: leftover.appending(path: "cookies.txt"))

        YTDLPRunner.removeLeftoverCookies(in: cookieFolder)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}
