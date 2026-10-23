import DowlioCore
import Foundation

extension URL {
    /// `http://`, whose bytes travel unencrypted (ADR 0003).
    var isPlainHTTP: Bool { scheme?.lowercased() == "http" }
}

/// Owns every download and is the only way in: add a download, then follow its snapshots.
public actor DownloadEngine {
    private struct DownloadEntry {
        var snapshot: DownloadSnapshot
        var observers: [UUID: AsyncStream<DownloadSnapshot>.Continuation] = [:]
        var task: Task<Void, Never>?
        let partialFile = PartialFileLocation()
        /// Kept so Retry can run it again from the bytes it has.
        var run: DownloadRun?
    }

    private var entries: [DownloadID: DownloadEntry] = [:]
    private let configuration: EngineConfiguration

    public init() {
        self.init(configuration: EngineConfiguration())
    }

    init(configuration: EngineConfiguration) {
        self.configuration = configuration
    }

    /// Starts downloading `url` into `folder` and returns the new download's identifier.
    public func add(url: URL, to folder: URL, options: RequestOptions = RequestOptions()) -> DownloadID {
        let id = DownloadID()
        let snapshot = DownloadSnapshot(
            id: id,
            state: .probing,
            fileName: FileNaming.name(for: url),
            destinationFolder: folder,
            isNotSecure: url.isPlainHTTP
        )
        let entry = DownloadEntry(snapshot: snapshot)
        entries[id] = entry

        let run = DownloadRun(
            url: url, folder: folder, options: options, partialFile: entry.partialFile, configuration: configuration
        ) { [weak self] change in
            await self?.update(id, change)
        }
        entries[id]?.run = run
        entries[id]?.task = Task { await run.run() }
        return id
    }

    /// Retries a Failed download (`GLOSSARY.md`): continues it from the bytes it has. Does nothing
    /// for a download that isn't Failed.
    public func retry(_ id: DownloadID) {
        guard let entry = entries[id], case .failed = entry.snapshot.state, let run = entry.run else { return }
        update(id) { $0.state = .downloading }
        entries[id]?.task = Task { await run.run() }
    }

    /// The download's current snapshot, then one snapshot per change. The stream ends after a
    /// terminal state, and at once for an unknown identifier.
    public func snapshots(of id: DownloadID) -> AsyncStream<DownloadSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadSnapshot.self)
        guard let record = entries[id] else {
            continuation.finish()
            return stream
        }
        continuation.yield(record.snapshot)
        if record.snapshot.state.isTerminal {
            continuation.finish()
            return stream
        }
        let token = UUID()
        entries[id]?.observers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token, from: id) }
        }
        return stream
    }

    /// Cancels a download (`GLOSSARY.md`): stops its connections, deletes its partial file and
    /// forgets it. The last snapshot is Cancelled. Does nothing for a Completed or unknown download.
    public func cancel(_ id: DownloadID) async {
        guard let entry = entries[id], entry.snapshot.state != .completed else { return }
        entry.task?.cancel()
        await entry.task?.value
        // The download may have finished while it was stopping. A finished file stays.
        guard entries[id]?.snapshot.state != .completed else { return }
        if let package = entry.partialFile.url {
            try? FileManager.default.removeItem(at: package)
        }
        update(id) { $0.state = .cancelled }
        entries[id] = nil
    }

    private func update(_ id: DownloadID, _ change: @Sendable (inout DownloadSnapshot) -> Void) {
        guard var record = entries[id] else { return }
        change(&record.snapshot)
        let snapshot = record.snapshot
        for observer in record.observers.values {
            observer.yield(snapshot)
            if snapshot.state.isTerminal { observer.finish() }
        }
        if snapshot.state.isTerminal { record.observers = [:] }
        entries[id] = record
    }

    private func removeObserver(_ token: UUID, from id: DownloadID) {
        entries[id]?.observers[token] = nil
    }
}
