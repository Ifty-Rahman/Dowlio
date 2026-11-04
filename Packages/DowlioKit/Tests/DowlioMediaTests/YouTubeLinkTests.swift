import DowlioCore
import DowlioMedia
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct YouTubeLinkTests {
    private let watch = URL(string: "https://www.youtube.com/watch?v=2Vv-BfVoq4g")!

    private func analyze(_ url: URL, with standIn: YTDLPStandIn, inspected: InspectLog = InspectLog()) async throws -> PageAnalysis {
        let analyzer = PageAnalyzer(readers: [], ytdlp: YTDLPRunner(installer: standIn.installer)) { url, _ in
            inspected.add(url)
            throw URLError(.cannotConnectToHost)
        }
        var last: PageAnalysis?
        for await update in analyzer.analyze(SentPage(url: url)) { last = update }
        return try #require(last)
    }

    @Test func aWatchLinkGoesStraightToYTDLPAndShowsTheVideosTitleThumbnailAndDuration() async throws {
        let standIn = try await YTDLPStandIn.printing("video-1080p.json")
        let inspected = InspectLog()

        let found = try await analyze(watch, with: standIn, inspected: inspected)

        guard case .found(let candidates) = found, let video = candidates.first else { Issue.record("not found: \(found)"); return }
        #expect(candidates.count == 1)
        #expect(video.label == "Ed Sheeran - Perfect (Official Music Video)")
        #expect(video.thumbnail == URL(string: "https://i.ytimg.com/vi/2Vv-BfVoq4g/hqdefault.jpg"))
        #expect(video.duration == 282)
        #expect(inspected.urls.isEmpty)
    }

    @Test func ytdlpRunsWithItsOwnSettingsTheJavaScriptRuntimeAndAClearedEnvironment() async throws {
        let standIn = try await YTDLPStandIn.printing("video-1080p.json")

        _ = try await analyze(watch, with: standIn)

        let tools = try await standIn.installer.verifiedTools()
        let arguments = standIn.arguments
        #expect(arguments.contains("--ignore-config"))
        #expect(arguments.contains("--no-playlist"))
        #expect(arguments.contains("--dump-single-json"))
        #expect(arguments.contains("quickjs:\(tools.quickJS.path)"))
        #expect(arguments.last == watch.absoluteString)
        #expect(!arguments.contains { $0.hasPrefix("--cookies") })
        #expect(Set(standIn.environment.keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD"]) == ["PATH", "HOME"])
    }

    @Test func beforeTheToolsAreInstalledAWatchLinkAsksForConsent() async throws {
        let standIn = try await YTDLPStandIn.notInstalled()

        let found = try await analyze(watch, with: standIn)

        #expect(found == .needsTools)
    }

    @Test func aToolThatChangedAfterInstallingIsNotRunAndOffersReinstalling() async throws {
        let standIn = try await YTDLPStandIn.printing("video-1080p.json")
        let tools = try await standIn.installer.verifiedTools()
        try Data("#!/bin/sh\necho swapped\n".utf8).write(to: tools.ytdlp)

        let found = try await analyze(watch, with: standIn)

        #expect(found == .toolsChanged)
        #expect(standIn.runs == 0)
    }

    @Test func aRunPastTheTimeoutIsStopped() async throws {
        let standIn = try await YTDLPStandIn.install(script: "exec sleep 30")
        let analyzer = PageAnalyzer(readers: [], ytdlp: YTDLPRunner(installer: standIn.installer, timeout: .milliseconds(500))) { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        let started = ContinuousClock.now

        var last: PageAnalysis?
        for await update in analyzer.analyze(SentPage(url: watch)) { last = update }

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(last != nil)
    }
}

final class InspectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []

    func add(_ url: URL) { lock.withLock { seen.append(url) } }

    var urls: [URL] { lock.withLock { seen } }
}
