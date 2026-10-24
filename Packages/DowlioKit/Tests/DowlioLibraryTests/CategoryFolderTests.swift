import DowlioCore
import DowlioLibrary
import DowlioTestSupport
import Foundation
import Testing

/// "Sort into category folders" from adding a link to the finished file on disk.
@Suite(.timeLimit(.minutes(1)))
struct CategoryFolderTests {
    @Test func eachCategoryLandsInItsOwnFolderAndAFileWithNoneLandsInTheDownloadFolder() async throws {
        let fixture = try await LibraryFixture()
        let server = try await TestServer()
        let files: [(name: String, category: FileCategory?)] = [
            ("talk.mp4", .video), ("song.mp3", .audio), ("Report.pdf", .documents),
            ("source.zip", .archives), ("Installer.dmg", .appsAndDiskImages), ("blob.dat", nil),
        ]
        var ids: [DownloadID] = []
        for (index, file) in files.enumerated() {
            server.serve(.init(data: TestServer.makeData(size: 2048, seed: UInt64(500 + index)), eTag: "\"c\(index)\""), at: "/\(file.name)")
            ids.append(await fixture.library.add(server.url(for: "/\(file.name)"), destination: .categoryFolders(under: fixture.folder)))
        }

        for (id, file) in zip(ids, files) {
            let row = try await fixture.library.row(id) { $0.state == .completed }
            let folder = file.category.map { fixture.folder.appending(path: $0.folderName, directoryHint: .isDirectory) } ?? fixture.folder
            #expect(row.category == file.category)
            #expect(row.folder.standardizedFileURL == folder.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: file.name).path))
        }

        let relaunched = try await fixture.relaunched()
        let rows = try await relaunched.library.firstRows { $0.count == files.count }
        #expect(Set(rows.map(\.category)) == Set(files.map(\.category)))
    }
}
