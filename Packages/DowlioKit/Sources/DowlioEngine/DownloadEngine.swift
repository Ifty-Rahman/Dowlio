import DowlioCore
import Foundation

extension URL {
    /// `http://`, whose bytes travel unencrypted (ADR 0003).
    var isPlainHTTP: Bool { scheme?.lowercased() == "http" }

    /// The host as the snapshot shows it: lowercased, `nil` when the link has none.
    var displayHost: String? { host(percentEncoded: false)?.lowercased() }
}

/// Why a partial file couldn't be restored.
public enum RestoreError: Error, Equatable, Sendable {
    /// The partial file has no manifest, or one this version of Dowlio can't read.
    case unreadableManifest
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
    /// Followers of every download's snapshots (`allSnapshots()`).
    private var allObservers: [UUID: AsyncStream<DownloadSnapshot>.Continuation] = [:]
    private let configuration: EngineConfiguration

    /// An engine whose learned host limits live in `hostLimits`. The default keeps them in memory.
    public init(hostLimits: any HostLimitStore = InMemoryHostLimitStore()) {
        var configuration = EngineConfiguration()
        configuration.hostLimits = hostLimits
        self.init(configuration: configuration)
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
            isNotSecure: url.isPlainHTTP,
            displayHost: url.displayHost
        )
        let entry = DownloadEntry(snapshot: snapshot)
        entries[id] = entry
        publishToAll(snapshot)

        let run = DownloadRun(
            id: id, url: url, folder: folder, options: options, partialFile: entry.partialFile, configuration: configuration
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
        guard let entry = entries[id], entry.snapshot.state.isFailed, let run = entry.run else { return }
        update(id) { $0.state = .downloading }
        entries[id]?.task = Task { await run.run() }
    }

    /// Pauses a download (`GLOSSARY.md`): stops every connection and keeps the bytes it has.
    /// Does nothing unless the download is probing, downloading or retrying.
    public func pause(_ id: DownloadID) async {
        guard let entry = entries[id], entry.snapshot.state.isFetching else { return }
        entry.task?.cancel()
        await entry.task?.value
        // The download may have finished or failed while it was stopping.
        guard entries[id]?.snapshot.state.isFetching == true else { return }
        update(id) {
            $0.state = .paused
            $0.bytesPerSecond = 0
            $0.timeRemaining = nil
        }
    }

    /// Resumes a paused download (`GLOSSARY.md`) from the bytes it has. Does nothing for a
    /// download that isn't Paused.
    public func resume(_ id: DownloadID) {
        guard let entry = entries[id], entry.snapshot.state == .paused, let run = entry.run else { return }
        update(id) { $0.state = .downloading }
        entries[id]?.task = Task { await run.run(resuming: true) }
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

    /// Every download's current snapshot, in no particular order, then one snapshot per change of
    /// any download, including each new download's first snapshot and a cancelled download's
    /// last. The stream never ends on its own.
    public func allSnapshots() -> AsyncStream<DownloadSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadSnapshot.self)
        for entry in entries.values { continuation.yield(entry.snapshot) }
        let token = UUID()
        allObservers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAllObserver(token) }
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

    /// Adds the download held by the partial file at `package` as Paused, with the bytes it has,
    /// so Resume continues it. Returns the download's identifier. A partial file the engine already
    /// has returns that download. Throws `RestoreError.unreadableManifest`, and leaves the partial
    /// file alone, when its manifest is missing or unreadable.
    public func restore(partialFile package: URL) throws -> DownloadID {
        let package = package.standardizedFileURL
        if let known = entries.first(where: { $0.value.partialFile.url?.standardizedFileURL == package }) {
            return known.key
        }
        let manifest = try PartialFile.readManifest(in: package)
        let partial = try PartialFile.openExisting(package)

        let id = UUID(uuidString: manifest.downloadID).map(DownloadID.init(rawValue:)) ?? DownloadID()
        let folder = package.deletingLastPathComponent()
        var options = RequestOptions()
        options.connections = manifest.connections
        options.referrer = manifest.referrer
        options.userAgent = manifest.userAgent

        let segments = manifest.segments.map { ByteRange(start: $0.start, end: $0.end) }
        let prepared = Prepared(
            fileName: manifest.fileName,
            finalURL: manifest.finalURL,
            totalBytes: manifest.totalBytes,
            layout: manifest.layout == .ranges && manifest.totalBytes != nil ? .ranges(validator: manifest.validator) : .whole,
            segments: segments,
            partial: partial,
            board: ProgressBoard(segments: segments, received: manifest.segments.map(\.received))
        )

        var snapshot = DownloadSnapshot(
            id: id,
            state: .paused,
            fileName: manifest.fileName,
            destinationFolder: folder,
            totalBytes: manifest.totalBytes,
            isNotSecure: manifest.originalURL.isPlainHTTP || manifest.finalURL.isPlainHTTP,
            displayHost: manifest.originalURL.displayHost
        )
        snapshot.apply(prepared.board.reading)
        snapshot.canResume = prepared.canResume

        let entry = DownloadEntry(snapshot: snapshot)
        entries[id] = entry
        publishToAll(snapshot)
        let run = DownloadRun(
            id: id, url: manifest.originalURL, folder: folder, options: options,
            partialFile: entry.partialFile, configuration: configuration
        ) { [weak self] change in
            await self?.update(id, change)
        }
        run.adopt(prepared)
        entries[id]?.run = run
        return id
    }

    /// Where the download's partial file is, or `nil` before it exists, after the file is
    /// finished, and for an unknown download.
    public func partialFile(of id: DownloadID) -> URL? {
        entries[id]?.partialFile.url
    }

    private func update(_ id: DownloadID, _ change: @Sendable (inout DownloadSnapshot) -> Void) {
        guard var record = entries[id] else { return }
        let before = record.snapshot
        change(&record.snapshot)
        // A change that leaves the snapshot as it was sends nothing (story 26).
        guard record.snapshot != before else { return }
        let snapshot = record.snapshot
        for observer in record.observers.values {
            observer.yield(snapshot)
            if snapshot.state.isTerminal { observer.finish() }
        }
        if snapshot.state.isTerminal { record.observers = [:] }
        entries[id] = record
        publishToAll(snapshot)
    }

    private func publishToAll(_ snapshot: DownloadSnapshot) {
        for observer in allObservers.values { observer.yield(snapshot) }
    }

    private func removeAllObserver(_ token: UUID) {
        allObservers[token] = nil
    }

    private func removeObserver(_ token: UUID, from id: DownloadID) {
        entries[id]?.observers[token] = nil
    }
}
