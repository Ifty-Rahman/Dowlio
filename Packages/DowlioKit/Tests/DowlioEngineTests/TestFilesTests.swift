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

    @Test func aDifferenceSaysWhereAFileStopsMatchingAndWhatIsThere() throws {
        let folder = try TestFiles.makeFolder()
        let expected = Data((0..<64).map { UInt8($0) })
        var holed = expected
        holed.replaceSubrange(16..<24, with: Data(count: 8))
        try expected.write(to: folder.appending(path: "same"))
        try holed.write(to: folder.appending(path: "holed"))
        try expected.prefix(40).write(to: folder.appending(path: "short"))

        #expect(TestFiles.difference(of: folder.appending(path: "same"), from: expected) == nil)
        #expect(TestFiles.difference(of: folder.appending(path: "holed"), from: expected) == "64 bytes, expected 64; first difference at byte 16, 8 bytes differ from there, all zeros on disk")
        #expect(TestFiles.difference(of: folder.appending(path: "short"), from: expected) == "40 bytes, expected 64; matches up to the end of the shorter one")
        var lastByte = expected
        lastByte[63] = 0xFF
        try lastByte.write(to: folder.appending(path: "last"))
        #expect(TestFiles.difference(of: folder.appending(path: "last"), from: expected) == "64 bytes, expected 64; first difference at byte 63, 1 bytes differ from there, other data on disk")
    }
}
