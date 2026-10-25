import DowlioConnect
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ExtensionUpdateTests {
    private func hello(_ fixture: ConnectFixture, version: String) async throws -> ConnectClient {
        let token = try await fixture.pairedToken()
        let client = try await fixture.client()
        try await client.send(["v": 1, "type": "hello", "token": token, "version": version])
        return client
    }

    @Test func anOlderDowlioConnectIsToldToReloadRightAfterHello() async throws {
        let fixture = try await ConnectFixture(extensionVersion: "0.2.10")
        let client = try await hello(fixture, version: "0.2.9")

        let types = [try await client.receive(), try await client.receive(), try await client.receive()].compactMap { $0["type"] as? String }

        #expect(types == ["hello.ok", "settings.update", "extension.reload"])
    }

    @Test func anOlderDowlioConnectThatComesBackStillOldIsntToldToReloadAgain() async throws {
        let fixture = try await ConnectFixture(extensionVersion: "0.3.0")
        let token = try await fixture.pairedToken()
        let first = try await fixture.client()
        try await first.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        for _ in 0..<3 { _ = try await first.receive() }
        first.close()

        let again = try await fixture.client()
        try await again.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        _ = try await again.receive()
        _ = try await again.receive()

        await #expect(throws: ConnectClientError.self) { try await again.receive(timeout: .milliseconds(300)) }
        #expect(await fixture.server.browserLinks().map(\.state) == [.needsReload])
    }

    @Test(arguments: ["0.2.10", "0.3.0"])
    func aCurrentOrNewerDowlioConnectIsLeftAlone(version: String) async throws {
        let fixture = try await ConnectFixture(extensionVersion: "0.2.10")
        let client = try await hello(fixture, version: version)
        _ = try await client.receive()
        _ = try await client.receive()

        await #expect(throws: ConnectClientError.self) { try await client.receive(timeout: .milliseconds(300)) }
        #expect(await fixture.server.browserLinks().map(\.state) == [.connected])
    }

    @Test func aConnectedBrowserWithAnOlderDowlioConnectNeedsReloadAndReloadAsksForIt() async throws {
        let fixture = try await ConnectFixture(extensionVersion: "0.3.0")
        let client = try await hello(fixture, version: "0.2.0")
        for _ in 0..<3 { _ = try await client.receive() }

        let link = try #require(await fixture.server.browserLinks().first)
        let reloaded = await fixture.server.reload(link.id)
        let message = try await client.receive()

        #expect(link.state == .needsReload)
        #expect(reloaded)
        #expect(message["type"] as? String == "extension.reload")
    }

    @Test func theReloadedDowlioConnectComesBackConnectedWithoutPairingAgain() async throws {
        let fixture = try await ConnectFixture(extensionVersion: "0.3.0")
        let token = try await fixture.pairedToken()
        let old = try await fixture.client()
        try await old.send(["v": 1, "type": "hello", "token": token, "version": "0.2.0"])
        for _ in 0..<3 { _ = try await old.receive() }
        old.close()

        let new = try await fixture.client()
        try await new.send(["v": 1, "type": "hello", "token": token, "version": "0.3.0"])
        let reply = try await new.receive()

        #expect(reply["type"] as? String == "hello.ok")
        #expect(await fixture.server.browserLinks().map(\.state) == [.connected])
        #expect(try fixture.store.browserPairings().count == 1)
    }
}

struct ExtensionVersionTests {
    @Test(arguments: [
        ("0.2.9", "0.2.10", true),
        ("0.2.10", "0.2.10", false),
        ("1.0", "0.9.9", false),
        ("0.2", "0.2.1", true),
        ("garbage", "0.2.0", true),
    ])
    func versionsCompareByNumberNotByText(installed: String, bundled: String, older: Bool) {
        #expect(ExtensionVersion.isOlder(installed, than: bundled) == older)
    }

    @Test func aNewerBundledCopyReplacesTheFolderAndAnEqualOneDoesnt() throws {
        let bundled = try TestFiles.makeFolder()
        try Data(#"{"version":"0.3.0"}"#.utf8).write(to: bundled.appending(path: "manifest.json"))
        let folder = try TestFiles.makeFolder().appending(path: "Browser Extension", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":"0.2.0"}"#.utf8).write(to: folder.appending(path: "manifest.json"))

        #expect(try ExtensionFolder.updateIfOlder(from: bundled, to: folder))
        #expect(try !ExtensionFolder.updateIfOlder(from: bundled, to: folder))
        #expect(ExtensionFolder.version(at: folder) == "0.3.0")
    }

    @Test func aFolderThatWasNeverAddedIsLeftAlone() throws {
        let bundled = try TestFiles.makeFolder()
        try Data(#"{"version":"0.3.0"}"#.utf8).write(to: bundled.appending(path: "manifest.json"))
        let folder = try TestFiles.makeFolder().appending(path: "Browser Extension", directoryHint: .isDirectory)

        #expect(try !ExtensionFolder.updateIfOlder(from: bundled, to: folder))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
