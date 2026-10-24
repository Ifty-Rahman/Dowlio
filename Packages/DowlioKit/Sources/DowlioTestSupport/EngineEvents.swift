import DowlioCore
import DowlioEngine
import Foundation

/// Ways for a test to wait for something the engine does, instead of for a fixed time, before it
/// checks that nothing else happened.
public enum EngineEvents {
    /// Waits until the manifest in `package` was saved `count` more times. While a download runs,
    /// the engine saves it every 4 progress ticks, so 2 saves mean at least 4 ticks went by. Each
    /// save writes a new file and renames it into place, so the file changes identity every time.
    public static func waitForManifestSaves(_ count: Int, in package: URL) async throws {
        let manifest = package.appending(path: "manifest.json")
        var last = identity(of: manifest)
        var seen = 0
        while seen < count {
            try await Task.sleep(for: .milliseconds(20))
            let current = identity(of: manifest)
            if current != last {
                seen += 1
                last = current
            }
        }
    }

    private struct Identity: Equatable {
        let fileNumber: Int?
        let modified: Date?
    }

    private static func identity(of file: URL) -> Identity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        return Identity(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.intValue,
            modified: attributes[.modificationDate] as? Date
        )
    }
}

extension DownloadEngine {
    /// Runs one more download from `server` to the end, in a folder of its own, and returns its
    /// path on the server. A test that checks nothing more happens to another download runs this
    /// first, so the check follows real requests through the same engine and server.
    @discardableResult
    public func runOtherDownload(on server: TestServer) async throws -> String {
        let path = "/other-\(UUID().uuidString).bin"
        server.serve(.init(data: TestServer.makeData(size: 2 * 1024 * 1024, seed: 99)), at: path)
        let id = add(url: server.url(for: path), to: try TestFiles.makeFolder())
        let finished = try await completedOrFailed(id)
        guard finished.state == .completed else { throw EngineTestError.streamEnded(last: finished) }
        return path
    }
}

/// Every snapshot a stream delivered so far, readable from any task.
public final class SnapshotLog: @unchecked Sendable {
    // @unchecked: `stored` is only read or written under `lock`.
    private let lock = NSLock()
    private var stored: [DownloadSnapshot] = []

    public init() {}

    public var snapshots: [DownloadSnapshot] { lock.withLock { stored } }

    public func append(_ snapshot: DownloadSnapshot) {
        lock.withLock { stored.append(snapshot) }
    }

    /// Follows `id` in `engine` until its stream ends, and returns a task that ends with it.
    public static func follow(_ id: DownloadID, in engine: DownloadEngine) async -> (SnapshotLog, Task<Void, Never>) {
        let log = SnapshotLog()
        let stream = await engine.snapshots(of: id)
        let task = Task {
            for await snapshot in stream { log.append(snapshot) }
        }
        return (log, task)
    }
}
