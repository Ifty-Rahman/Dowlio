import DowlioCore
@testable import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// Cookies go with every request of their download, and never onto disk.
@Suite(.timeLimit(.minutes(1)))
struct CookieTests {
    static let size = 4 * 1024 * 1024
    static let secret = "s3cr3t-session-4f9a"

    private static var options: RequestOptions {
        var options = RequestOptions()
        options.connections = 2
        options.cookies = [Cookie(name: "session", value: secret), Cookie(name: "theme", value: "dark")]
        return options
    }

    private static let header = "session=\(secret); theme=dark"

    @Test func cookiesNeverFollowARedirectToAnotherHost() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 74)
        server.serve(.init(data: data, eTag: "\"x1\""), at: "/real.bin")
        // The link is on 127.0.0.1. It redirects to the same server under the host name
        // "localhost", so the file comes from a host the cookies don't belong to.
        server.redirect("/start.bin", to: "http://localhost:\(server.port)/real.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/start.bin"), to: folder, options: Self.options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        let toLinkHost = server.requests.filter { $0.path == "/start.bin" }
        let toOtherHost = server.requests.filter { $0.path == "/real.bin" }
        #expect(!toLinkHost.isEmpty)
        #expect(toLinkHost.allSatisfy { $0.headers["cookie"] == Self.header })
        #expect(!toOtherHost.isEmpty)
        #expect(toOtherHost.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test func theBrowsersFormAndHeadersGoOnlyToTheLinkNeverToARedirectsOtherHost() async throws {
        let linkServer = try await TestServer()
        let fileServer = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 76)
        fileServer.serve(.init(data: data, eTag: "\"x3\""), at: "/real.bin")
        linkServer.redirect("/start.bin", to: fileServer.url(for: "/real.bin").absoluteString)
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.browserRequest = BrowserRequest(
            method: "POST", body: Data("id=42".utf8),
            headers: [Header(name: "X-Token", value: Self.secret), Header(name: "Content-Type", value: "application/x-www-form-urlencoded")]
        )

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: linkServer.url(for: "/start.bin"), to: folder, options: options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(!linkServer.requests.isEmpty)
        #expect(linkServer.requests.allSatisfy { $0.method == "POST" && $0.body == Data("id=42".utf8) && $0.headers["x-token"] == Self.secret })
        #expect(!fileServer.requests.isEmpty)
        #expect(fileServer.requests.allSatisfy { $0.method == "GET" && $0.body.isEmpty && $0.headers["x-token"] == nil })
    }

    @Test func cookiesNeverFollowARedirectToAnotherPortOnTheSameHost() async throws {
        let linkServer = try await TestServer()
        let fileServer = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 75)
        fileServer.serve(.init(data: data, eTag: "\"x2\""), at: "/real.bin")
        linkServer.redirect("/start.bin", to: fileServer.url(for: "/real.bin").absoluteString)
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: linkServer.url(for: "/start.bin"), to: folder, options: Self.options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(!linkServer.requests.isEmpty)
        #expect(linkServer.requests.allSatisfy { $0.headers["cookie"] == Self.header })
        #expect(!fileServer.requests.isEmpty)
        #expect(fileServer.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test(arguments: [
        ("https://files.example.com/a", "https://files.example.com/b", true),
        ("https://Files.Example.com/a", "https://files.example.com:443/b", true),
        ("http://files.example.com/a", "http://files.example.com:80/b", true),
        ("https://files.example.com/a", "http://files.example.com/a", false),
        ("https://files.example.com/a", "https://files.example.com:8443/a", false),
        ("http://127.0.0.1:8080/a", "http://127.0.0.1:8081/a", false),
        ("https://files.example.com/a", "https://cdn.example.com/a", false),
    ])
    func cookiesGoOnlyToTheSameSchemeHostAndPort(from: String, to: String, sameOrigin: Bool) throws {
        let from = try #require(URL(string: from))
        let to = try #require(URL(string: to))
        #expect(from.hasSameOrigin(as: to) == sameOrigin)
    }

    @Test func everyRequestSendsTheCookiesIncludingRetries() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 71)
        server.serve(.init(data: data, eTag: "\"k1\"", dropFirst: .init(afterBytes: 64 * 1024, count: 1)), at: "/k.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/k.bin"), to: folder, options: Self.options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "k.bin")) == TestFiles.sha256(data))
        // The probe, two segments and the retry of the dropped one.
        #expect(server.requests.count >= 4)
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == Self.header })
    }

    @Test func theFallbackToOneConnectionSendsTheCookies() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 72)
        server.serve(.init(data: data, misreportRangeStartBy: 1, eTag: "\"k2\""), at: "/fallback.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/fallback.bin"), to: folder, options: Self.options)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: folder.appending(path: "fallback.bin")) == TestFiles.sha256(data))
        #expect(server.requests.contains { $0.headers["range"] == nil })
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == Self.header })
    }

    @Test func cookiesNeverReachThePartialFileAndAreGoneAfterARestore() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: Self.size, seed: 73)
        let held = 256 * 1024
        server.serve(.init(data: data, holdAfterBytes: held, eTag: "\"k3\""), at: "/kept.bin")
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/kept.bin"), to: folder, options: Self.options)
        _ = try await engine.firstSnapshot(of: id) { $0.receivedBytes == Int64(2 * held) }
        await engine.pause(id)
        let package = try #require(await engine.partialFile(of: id))

        let files = try #require(FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        #expect(files.contains { $0.lastPathComponent == "manifest.json" })
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(Self.secret.utf8)) == nil, "\(file.lastPathComponent) holds the cookie")
        }

        let fresh = DownloadEngine(configuration: .fast)
        let restored = try await fresh.restore(partialFile: package)
        server.releaseHeldResponses()
        let requestsBeforeResume = server.requests.count
        await fresh.resume(restored)
        let finished = try await fresh.completedOrFailed(restored)

        #expect(finished.state == .completed)
        #expect(server.requests[..<requestsBeforeResume].allSatisfy { $0.headers["cookie"] == Self.header })
        #expect(server.requests[requestsBeforeResume...].allSatisfy { $0.headers["cookie"] == nil })
    }
}
