import DowlioCore
import DowlioEngine
import DowlioTestSupport
import Foundation
import Testing

/// Category folders: the folder is chosen after the probe, from the file the server sends.
@Suite(.timeLimit(.minutes(1)))
struct DestinationTests {
    @Test func aFileGoesIntoTheFolderForItsCategoryWithOneProbe() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 3 * 1024 * 1024, seed: 101)
        server.serve(.init(data: data, eTag: "\"d1\""), at: "/source.zip")
        let root = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/source.zip"), destination: .categoryFolders(under: root))
        let finished = try await engine.completedOrFailed(id)

        let archives = root.appending(path: "Archives", directoryHint: .isDirectory)
        #expect(finished.state == .completed)
        #expect(finished.destinationFolder.standardizedFileURL == archives.standardizedFileURL)
        #expect(try TestFiles.sha256(of: archives.appending(path: "source.zip")) == TestFiles.sha256(data))
        #expect(server.requests.filter { $0.headers["range"] == "bytes=0-" }.count == 1)
    }

    @Test func theContentTypeDecidesWhenTheNameDoesnt() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024, seed: 102)
        let headers = ["Content-Disposition": #"attachment; filename="talk""#, "Content-Type": "video/mp4"]
        server.serve(.init(data: data, eTag: "\"d2\"", headers: headers), at: "/watch?v=1")
        let root = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/watch?v=1"), destination: .categoryFolders(under: root))
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Video/\(finished.fileName)").path))
    }

    @Test func aFileWithNoCategoryGoesStraightIntoTheRoot() async throws {
        let server = try await TestServer()
        let data = TestServer.makeData(size: 1024, seed: 103)
        server.serve(.init(data: data, eTag: "\"d3\""), at: "/blob.dat")
        let root = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: "/blob.dat"), destination: .categoryFolders(under: root))
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(try TestFiles.sha256(of: root.appending(path: "blob.dat")) == TestFiles.sha256(data))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["blob.dat"])
    }
}

extension DestinationTests {
    /// The snapshot says which Category the engine decided on, from the name and the content type.
    @Test(arguments: [
        ("/Report.pdf", [String: String](), FileCategory?.some(.documents)),
        ("/get", ["Content-Disposition": #"attachment; filename="clip""#, "Content-Type": "video/mp4"], .video),
        ("/blob.dat", [:], nil),
    ])
    func theSnapshotCarriesTheCategory(path: String, headers: [String: String], category: FileCategory?) async throws {
        let server = try await TestServer()
        server.serve(.init(data: TestServer.makeData(size: 1024, seed: 104), eTag: "\"d4\"", headers: headers), at: path)
        let folder = try TestFiles.makeFolder()

        let engine = DownloadEngine(configuration: .fast)
        let id = await engine.add(url: server.url(for: path), to: folder)
        let finished = try await engine.completedOrFailed(id)

        #expect(finished.state == .completed)
        #expect(finished.category == category)
    }
}
