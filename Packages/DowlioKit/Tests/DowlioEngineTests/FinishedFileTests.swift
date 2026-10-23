import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// File names, name conflicts and what a finished file carries (ticket 09).
@Suite(.timeLimit(.minutes(1)))
struct FinishedFileTests {
    /// Downloads `path` from a server serving `file` there, and returns the finished snapshot.
    private func download(
        _ file: TestServer.File,
        at path: String,
        into folder: URL,
        options: RequestOptions = RequestOptions()
    ) async throws -> DownloadSnapshot {
        let server = try await TestServer()
        server.serve(file, at: path)
        let engine = DownloadEngine()
        let id = await engine.add(url: server.url(for: path), to: folder, options: options)
        return try await engine.finished(id)
    }

    @Test func theNameComesFromContentDisposition() async throws {
        let folder = try TestFiles.makeFolder()
        let data = TestServer.makeData(size: 64 * 1024)
        let file = TestServer.File(data: data, headers: ["Content-Disposition": #"attachment; filename="Quarterly Report.pdf""#])

        let finished = try await download(file, at: "/download.php", into: folder)

        #expect(finished.state == .completed)
        #expect(finished.fileName == "Quarterly Report.pdf")
        #expect(try TestFiles.sha256(of: folder.appending(path: "Quarterly Report.pdf")) == TestFiles.sha256(data))
    }

    @Test func anEncodedFileNameWinsOverThePlainOne() async throws {
        let folder = try TestFiles.makeFolder()
        let header = #"attachment; filename="resume.txt"; filename*=UTF-8''r%C3%A9sum%C3%A9%20final.txt"#
        let file = TestServer.File(data: TestServer.makeData(size: 1024), headers: ["Content-Disposition": header])

        let finished = try await download(file, at: "/cv", into: folder)

        #expect(finished.fileName == "résumé final.txt")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "résumé final.txt").path))
    }

    @Test func withoutAHeaderTheNameComesFromTheDecodedLink() async throws {
        let folder = try TestFiles.makeFolder()

        let finished = try await download(.init(data: TestServer.makeData(size: 1024)), at: "/files/My%20Report%20%232.pdf", into: folder)

        #expect(finished.fileName == "My Report #2.pdf")
    }

    @Test func aNameWithoutAnExtensionGetsOneFromTheContentType() async throws {
        let folder = try TestFiles.makeFolder()
        let file = TestServer.File(data: TestServer.makeData(size: 1024), headers: ["Content-Type": "application/zip"])

        let finished = try await download(file, at: "/get", into: folder)

        #expect(finished.fileName == "get.zip")
    }

    @Test(arguments: [
        ("UTF-8''..%2F..%3Aevil%01%0Aname.txt", "evilname.txt"),
        ("UTF-8''...", "download"),
    ])
    func unsafeCharactersAreRemovedFromTheName(encoded: String, expected: String) async throws {
        let folder = try TestFiles.makeFolder()
        let file = TestServer.File(data: TestServer.makeData(size: 1024), headers: ["Content-Disposition": "attachment; filename*=\(encoded)"])

        let finished = try await download(file, at: "/x", into: folder)

        #expect(finished.fileName == expected)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: expected).path))
    }

    @Test func aLongNameIsCutTo200BytesAndKeepsItsExtension() async throws {
        let folder = try TestFiles.makeFolder()
        let encodedLongName = String(repeating: "%C3%A9", count: 300) + ".txt"
        let file = TestServer.File(data: TestServer.makeData(size: 1024), headers: ["Content-Disposition": "attachment; filename*=UTF-8''\(encodedLongName)"])

        let finished = try await download(file, at: "/long", into: folder)

        #expect(finished.fileName.utf8.count <= 200)
        #expect(finished.fileName == String(repeating: "é", count: 98) + ".txt")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: finished.fileName).path))
    }

    @Test func keepBothTakesTheNextFreeNumber() async throws {
        let folder = try TestFiles.makeFolder()
        try Data("one".utf8).write(to: folder.appending(path: "photo.jpg"))
        try Data("two".utf8).write(to: folder.appending(path: "photo 2.jpg"))

        let finished = try await download(.init(data: TestServer.makeData(size: 1024)), at: "/photo.jpg", into: folder)

        #expect(finished.state == .completed)
        #expect(finished.fileName == "photo 3.jpg")
        #expect(try Data(contentsOf: folder.appending(path: "photo.jpg")) == Data("one".utf8))
        #expect(try Data(contentsOf: folder.appending(path: "photo 2.jpg")) == Data("two".utf8))
    }

    @Test func replaceOverwritesTheExistingFile() async throws {
        let folder = try TestFiles.makeFolder()
        try Data("old".utf8).write(to: folder.appending(path: "build.zip"))
        let data = TestServer.makeData(size: 1024)
        var options = RequestOptions()
        options.nameConflictPolicy = .replace

        let finished = try await download(.init(data: data), at: "/build.zip", into: folder, options: options)

        #expect(finished.state == .completed)
        #expect(finished.fileName == "build.zip")
        #expect(try TestFiles.sha256(of: folder.appending(path: "build.zip")) == TestFiles.sha256(data))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["build.zip"])
    }

    @Test func skipKeepsTheExistingFileAndLeavesNothingElse() async throws {
        let folder = try TestFiles.makeFolder()
        try Data("mine".utf8).write(to: folder.appending(path: "song.mp3"))
        var options = RequestOptions()
        options.nameConflictPolicy = .skip

        let finished = try await download(.init(data: TestServer.makeData(size: 1024)), at: "/song.mp3", into: folder, options: options)

        #expect(finished.state == .completed)
        #expect(try Data(contentsOf: folder.appending(path: "song.mp3")) == Data("mine".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["song.mp3"])
    }

    @Test func skipReportsTheDownloadsOwnNameAndThatItWasSkipped() async throws {
        let folder = try TestFiles.makeFolder()
        try Data("mine".utf8).write(to: folder.appending(path: "Song.mp3"))
        var options = RequestOptions()
        options.nameConflictPolicy = .skip
        let file = TestServer.File(data: TestServer.makeData(size: 1024), headers: ["Content-Disposition": #"attachment; filename="Song.mp3""#])

        let finished = try await download(file, at: "/track", into: folder, options: options)

        #expect(finished.state == .completed)
        #expect(finished.fileName == "Song.mp3")
        #expect(finished.wasSkipped)
    }

    @Test(arguments: [NameConflictPolicy.keepBoth, .replace, .skip])
    func aDownloadWithoutANameConflictIsNotSkipped(policy: NameConflictPolicy) async throws {
        let folder = try TestFiles.makeFolder()
        var options = RequestOptions()
        options.nameConflictPolicy = policy

        let finished = try await download(.init(data: TestServer.makeData(size: 1024)), at: "/new.txt", into: folder, options: options)

        #expect(finished.state == .completed)
        #expect(!finished.wasSkipped)
    }

    @Test func keepBothIsNotSkipped() async throws {
        let folder = try TestFiles.makeFolder()
        try Data("one".utf8).write(to: folder.appending(path: "clip.mov"))

        let finished = try await download(.init(data: TestServer.makeData(size: 1024)), at: "/clip.mov", into: folder)

        #expect(finished.fileName == "clip 2.mov")
        #expect(!finished.wasSkipped)
    }

    @Test func aFinishedFileIsMarkedAsDownloadedFromTheInternetByDowlio() async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024)), at: "/Installer.dmg")
        let folder = try TestFiles.makeFolder()
        let source = server.url(for: "/Installer.dmg")

        let engine = DownloadEngine()
        let id = await engine.add(url: source, to: folder)
        _ = try await engine.finished(id)

        // The file's quarantine attribute keeps the agent. macOS stores the origin URL in its own
        // quarantine database, so it can't be read back from the file.
        let values = try folder.appending(path: "Installer.dmg").resourceValues(forKeys: [.quarantinePropertiesKey])
        let quarantine = try #require(values.quarantineProperties)
        #expect(quarantine[kLSQuarantineAgentNameKey as String] as? String == "Dowlio")
    }

    @Test func aPlainHTTPDownloadIsMarkedNotSecure() async throws {
        let folder = try TestFiles.makeFolder()

        let finished = try await download(.init(data: TestServer.makeData(size: 1024)), at: "/plain.txt", into: folder)

        #expect(finished.state == .completed)
        #expect(finished.isNotSecure)
    }

    @Test func anHTTPSDownloadIsNotMarkedNotSecure() async throws {
        let folder = try TestFiles.makeFolder()
        let engine = DownloadEngine()
        // Nothing listens on port 1, so this only checks the snapshot before the download fails.
        let id = await engine.add(url: URL(string: "https://127.0.0.1:1/secure.zip")!, to: folder)

        let first = try await engine.firstSnapshot(of: id) { _ in true }

        #expect(!first.isNotSecure)
    }
}
