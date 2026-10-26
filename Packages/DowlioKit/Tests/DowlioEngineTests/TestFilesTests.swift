import DowlioTestSupport
import Foundation
import Testing

struct TestFilesTests {
    @Test func foldersLiveInsideThisRunsFolder() throws {
        let folder = try TestFiles.makeFolder()

        #expect(folder.deletingLastPathComponent() == TestFiles.runFolder)
        #expect(TestFiles.runFolder.lastPathComponent == "run-\(getpid())")
    }

    @Test func foldersFromRunsThatEndedAreRemovedAndLiveOnesKept() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "TestFilesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["run-111", "run-222", "notes"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }

        TestFiles.removeEndedRuns(in: root) { $0 == 222 }

        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["notes", "run-222"])
    }
}
