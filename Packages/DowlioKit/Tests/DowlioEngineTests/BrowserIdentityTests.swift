import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BrowserIdentityTests {
    @Test func theSystemsLanguagesAreSentInPreferenceOrder() {
        #expect(BrowserIdentity(userAgent: nil, languages: ["en-GB", "bn-BD", "fr"]).acceptLanguage == "en-GB,bn-BD;q=0.9,fr;q=0.8")
        #expect(BrowserIdentity(userAgent: nil, languages: []).acceptLanguage == nil)
    }

    @Test func aDownloadWithNoUserAgentOfItsOwnIsAskedForWithDowliosOwn() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024)), at: "/file.zip")
        var configuration = EngineConfiguration.fast
        configuration.identity = { BrowserIdentity(userAgent: "WebKitTest/1", languages: ["en-GB", "bn-BD"]) }
        let engine = DownloadEngine(configuration: configuration)

        let id = await engine.add(url: server.url(for: "/file.zip"), to: try TestFiles.makeFolder())
        _ = try await engine.completedOrFailed(id)

        let requests = server.requests.filter { $0.path == "/file.zip" }
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.headers["user-agent"] == "WebKitTest/1" && $0.headers["accept-language"] == "en-GB,bn-BD;q=0.9" })
    }

    @Test func aLinkAskedForWithDowliosOwnIdentityLooksLikeABrowserNavigation() async throws {
        let server = try await TestServer()
        server.serve(.init(data: Data("<title>Page</title>".utf8), headers: ["Content-Type": "text/html"]), at: "/reel/1")
        var configuration = EngineConfiguration.fast
        configuration.identity = { BrowserIdentity(userAgent: "WebKitTest/1", languages: ["en-GB"]) }

        _ = try await DownloadEngine(configuration: configuration).inspect(server.url(for: "/reel/1"))

        let asked = try #require(server.requests.first { $0.path == "/reel/1" })
        #expect(asked.headers["sec-fetch-mode"] == "navigate")
        #expect(asked.headers["sec-fetch-dest"] == "document")
        #expect(asked.headers["sec-fetch-site"] == "none")
        #expect(asked.headers["accept"]?.hasPrefix("text/html") == true)
    }

    @Test func aLinkWithABrowsersOwnUserAgentIsAskedForAsThatBrowserAsksNotAsANavigation() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024)), at: "/file.zip")
        var configuration = EngineConfiguration.fast
        configuration.identity = { BrowserIdentity(userAgent: "WebKitTest/1", languages: ["en-GB"]) }
        var options = RequestOptions()
        options.userAgent = "Browser/2"

        _ = try await DownloadEngine(configuration: configuration).inspect(server.url(for: "/file.zip"), options: options)

        let asked = try #require(server.requests.first { $0.path == "/file.zip" })
        #expect(asked.headers["sec-fetch-mode"] == nil)
    }

    @Test func aDownloadsOwnUserAgentAndOriginAreKept() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 64 * 1024)), at: "/file.zip")
        var configuration = EngineConfiguration.fast
        configuration.identity = { BrowserIdentity(userAgent: "WebKitTest/1", languages: ["en-GB"]) }
        let engine = DownloadEngine(configuration: configuration)
        var options = RequestOptions()
        options.userAgent = "Browser/2"
        options.origin = "https://player.example"

        let id = await engine.add(url: server.url(for: "/file.zip"), to: try TestFiles.makeFolder(), options: options)
        _ = try await engine.completedOrFailed(id)

        let requests = server.requests.filter { $0.path == "/file.zip" }
        #expect(requests.allSatisfy { $0.headers["user-agent"] == "Browser/2" && $0.headers["origin"] == "https://player.example" })
    }
}
