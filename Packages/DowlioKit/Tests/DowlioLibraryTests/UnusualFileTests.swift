import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct UnusualFileTests {
    private func download(_ name: String, type: String?, disposition: String? = nil, seed: UInt64) async throws -> (DownloadRow, URL) {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        var headers: [String: String] = [:]
        if let type { headers["Content-Type"] = type }
        if let disposition { headers["Content-Disposition"] = disposition }
        server.serve(.init(data: TestServer.makeData(size: 2048, seed: seed), eTag: "\"u\(seed)\"", headers: headers), at: "/files/\(name)")
        let id = await fixture.add(server.url(for: "/files/\(name)"))
        let row = try await fixture.library.row(id) { $0.state == .completed }
        return (row, fixture.folder)
    }

    @Test(arguments: [
        ("ubuntu.torrent", "application/x-bittorrent"),
        ("ubuntu.torrent", "application/octet-stream"),
        ("ubuntu.torrent", "text/plain; charset=utf-8"),
        ("wg0.conf", "text/plain"),
        ("wg0.conf", "application/octet-stream"),
        ("nginx.conf", "text/plain; charset=utf-8"),
        ("app.conf", "text/x-config"),
    ])
    func anUnusualFileKeepsItsNameAndFinishes(name: String, type: String) async throws {
        let (row, folder) = try await download(name, type: type, seed: UInt64(name.count + type.count))

        #expect(row.fileName == name)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))
        #expect(row.badge == (name as NSString).pathExtension.uppercased())
    }

    @Test func aNameFromTheServerKeepsItsExtensionWhenTheTypeIsPlainText() async throws {
        let (row, _) = try await download("get", type: "text/plain", disposition: "attachment; filename=\"site.conf\"", seed: 77)

        #expect(row.fileName == "site.conf")
    }

    @Test func torrentAndConfigFilesAreDocuments() {
        #expect(FileCategory(fileName: "ubuntu.torrent", contentType: "application/x-bittorrent") == .documents)
        #expect(FileCategory(fileName: "wg0.conf", contentType: nil) == .documents)
    }
}
