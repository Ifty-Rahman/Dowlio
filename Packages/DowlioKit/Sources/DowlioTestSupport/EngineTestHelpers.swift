import CryptoKit
import DowlioCore
import DowlioEngine
import Foundation

public enum EngineTestError: Error {
    case streamEnded(last: DownloadSnapshot?)
    case notOnePartialFile(found: [URL])
}

extension DownloadEngine {
    /// Waits for the first snapshot of `id` that matches `condition`.
    public func firstSnapshot(
        of id: DownloadID,
        where condition: @Sendable (DownloadSnapshot) -> Bool
    ) async throws -> DownloadSnapshot {
        var last: DownloadSnapshot?
        for await snapshot in snapshots(of: id) {
            last = snapshot
            if condition(snapshot) { return snapshot }
        }
        throw EngineTestError.streamEnded(last: last)
    }

    public func completedOrFailed(_ id: DownloadID) async throws -> DownloadSnapshot {
        try await firstSnapshot(of: id) { $0.state == .completed || $0.state.isFailed }
    }
}

/// Polls `condition` every 20 ms until it holds. The suite's time limit ends a wait that never
/// succeeds.
public func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    while !condition() {
        try await Task.sleep(for: .milliseconds(20))
    }
}

public enum TestFiles {
    /// A fresh empty folder under the temporary directory.
    public static func makeFolder() throws -> URL {
        let folder = runFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public static let runFolder: URL = {
        let root = FileManager.default.temporaryDirectory.appending(path: "DowlioTests", directoryHint: .isDirectory)
        removeEndedRuns(in: root) { kill($0, 0) == 0 || errno == EPERM }
        atexit { try? FileManager.default.removeItem(at: TestFiles.runFolder) }
        return root.appending(path: "run-\(getpid())", directoryHint: .isDirectory)
    }()

    public static func removeEndedRuns(in root: URL, isRunning: (pid_t) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix("run-") {
            guard let pid = pid_t(name.dropFirst(4)), !isRunning(pid) else { continue }
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of file: URL) throws -> String {
        try sha256(Data(contentsOf: file))
    }
}
