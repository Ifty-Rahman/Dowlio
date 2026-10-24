import DowlioCore
import DowlioEngine
import DowlioStore
import Foundation

/// Every download Dowlio knows, past and present: the engine's live downloads joined with History.
/// It's the only writer of the store, so it reads the store once, at `start()`.
public actor Library {
    private let engine: DownloadEngine
    private let store: DownloadStore
    private let now: @Sendable () -> Date
    private let trash: @Sendable (URL) throws -> Void

    private var records: [DownloadID: StoredDownload] = [:]
    private var snapshots: [DownloadID: DownloadSnapshot] = [:]
    private var inEngine: Set<DownloadID> = []
    /// Cookies never reach the store, so a download that hasn't started keeps them here until it
    /// does.
    private var waitingCookies: [DownloadID: [Cookie]] = [:]
    private var missingFiles: Set<DownloadID> = []
    private var observers: [UUID: AsyncStream<[DownloadRow]>.Continuation] = [:]
    private var published: [DownloadRow]?
    private var following: Task<Void, Never>?
    private var maximumActive = 3

    public init(
        engine: DownloadEngine,
        store: DownloadStore,
        now: @escaping @Sendable () -> Date = { Date() },
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.engine = engine
        self.store = store
        self.now = now
        self.trash = trash
    }

    /// Reads History and brings every unfinished download back Paused. Call it once, at launch.
    public func start() async {
        for var record in (try? store.all()) ?? [] {
            let id = DownloadID(rawValue: record.id)
            switch record.state {
            case .completed:
                if !Self.finishedFileExists(record) { missingFiles.insert(id) }
            case .queued:
                break
            case .paused, .downloading, .failed:
                if await restore(record) {
                    inEngine.insert(id)
                } else {
                    record.partialFile = nil
                }
                record.state = .paused
                save(record)
            }
            records[id] = record
        }
        following = Task { [weak self, engine] in
            for await snapshot in await engine.allSnapshots() {
                await self?.apply(snapshot)
            }
        }
        publish()
    }

    /// The rows now, then the rows after each change that shows. Newest added first.
    public func rows() -> AsyncStream<[DownloadRow]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [DownloadRow].self)
        continuation.yield(currentRows())
        let token = UUID()
        observers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    /// Adds `url` and starts it, or keeps it Paused when `startImmediately` is false.
    @discardableResult
    public func add(
        _ url: URL,
        destination: Destination,
        options: RequestOptions = RequestOptions(),
        startImmediately: Bool = true
    ) async -> DownloadID {
        let id = DownloadID()
        let record = StoredDownload(
            id: id.rawValue, sourceURL: url, destination: destination, options: options,
            state: .paused, addedAt: now()
        )
        records[id] = record
        save(record)
        if !options.cookies.isEmpty { waitingCookies[id] = options.cookies }
        publish()
        if startImmediately { await runOrQueue(id) }
        return id
    }

    /// How many downloads run at once. The rest wait Queued, oldest first. Raising it starts
    /// waiting downloads at once. Lowering it lets running downloads finish.
    public func setMaximumActive(_ limit: Int) async {
        maximumActive = max(limit, 1)
        await fillSlots()
    }

    /// Stops a download, or takes a Queued one off the queue.
    public func pause(_ id: DownloadID) async {
        guard var record = records[id] else { return }
        if record.state == .queued {
            record.state = .paused
            records[id] = record
            save(record)
            publish()
        } else if inEngine.contains(id) {
            await engine.pause(id)
        }
    }

    /// Continues a Paused download, or queues it when the limit is reached. One that never reached
    /// the engine, or whose partial file is gone, starts from its link.
    public func resume(_ id: DownloadID) async {
        guard records[id]?.state == .paused else { return }
        await runOrQueue(id)
    }

    /// Continues a Failed download, or queues it when the limit is reached.
    public func retry(_ id: DownloadID) async {
        guard records[id]?.state == .failed else { return }
        await runOrQueue(id)
    }

    /// Pauses every download that runs or waits. Failed downloads stay as they are.
    public func pauseAll() async {
        for (id, record) in records where record.state == .downloading || record.state == .queued {
            await pause(id)
        }
    }

    /// Resumes every Paused download, oldest first. Those beyond the limit wait Queued.
    public func resumeAll() async {
        let paused = records.values.filter { $0.state == .paused }.sorted { $0.addedAt < $1.addedAt }
        for record in paused { await resume(DownloadID(rawValue: record.id)) }
    }

    private var activeCount: Int {
        records.values.count { $0.state == .downloading }
    }

    private func runOrQueue(_ id: DownloadID) async {
        guard var record = records[id] else { return }
        guard activeCount < maximumActive else {
            record.state = .queued
            records[id] = record
            save(record)
            publish()
            return
        }
        await run(id)
    }

    private func run(_ id: DownloadID) async {
        guard inEngine.contains(id), var record = records[id] else { return await startInEngine(id) }
        let failed = snapshots[id]?.state.isFailed ?? false
        record.state = .downloading
        records[id] = record
        save(record)
        publish()
        if failed { await engine.retry(id) } else { await engine.resume(id) }
    }

    private func fillSlots() async {
        while activeCount < maximumActive,
              let next = records.values.filter({ $0.state == .queued }).min(by: { $0.addedAt < $1.addedAt }) {
            await run(DownloadID(rawValue: next.id))
        }
    }

    /// What `url` gives, without adding it. Throws `DownloadError`.
    public nonisolated func inspect(_ url: URL, options: RequestOptions = RequestOptions()) async throws -> LinkInspection {
        try await engine.inspect(url, options: options)
    }

    /// Throws the download away: its partial file, its row and its record.
    public func cancel(_ id: DownloadID) async {
        guard let record = records[id], record.state != .completed else { return }
        records[id] = nil
        snapshots[id] = nil
        inEngine.remove(id)
        waitingCookies[id] = nil
        try? store.delete(id.rawValue)
        publish()
        await engine.cancel(id)
        if let package = record.partialFile { try? FileManager.default.removeItem(at: package) }
        await fillSlots()
    }

    /// Takes the row off the list. A Completed download's file stays. Anything with a partial
    /// file is cancelled, so the partial file doesn't stay behind.
    public func removeFromList(_ id: DownloadID) async {
        guard let record = records[id] else { return }
        guard record.state == .completed else { return await cancel(id) }
        forget(id)
        publish()
    }

    /// Sends a Completed download's file to the Trash and takes the row off the list. Throws, and
    /// keeps the row, when the Trash refuses the file.
    public func moveToTrash(_ id: DownloadID) throws {
        guard let record = records[id], record.state == .completed else { return }
        if Self.finishedFileExists(record) {
            try trash(record.folder.appending(path: record.fileName))
        }
        forget(id)
        publish()
    }

    /// Takes every Completed row off the list. Their files stay.
    public func clearCompleted() {
        for (id, record) in records where record.state == .completed { forget(id) }
        publish()
    }

    /// Checks again that every Completed download's file is where Dowlio put it.
    public func checkFinishedFiles() {
        for (id, record) in records where record.state == .completed {
            if Self.finishedFileExists(record) { missingFiles.remove(id) } else { missingFiles.insert(id) }
        }
        publish()
    }

    private func forget(_ id: DownloadID) {
        records[id] = nil
        snapshots[id] = nil
        missingFiles.remove(id)
        try? store.delete(id.rawValue)
    }

    private static func finishedFileExists(_ record: StoredDownload) -> Bool {
        FileManager.default.fileExists(atPath: record.folder.appending(path: record.fileName).path)
    }

    private func startInEngine(_ id: DownloadID) async {
        guard var record = records[id] else { return }
        var options = record.options
        options.cookies = waitingCookies.removeValue(forKey: id) ?? []
        record.state = .downloading
        records[id] = record
        save(record)
        inEngine.insert(id)
        await engine.add(url: record.sourceURL, destination: record.destination, options: options, id: id)
    }

    private func restore(_ record: StoredDownload) async -> Bool {
        guard let package = record.partialFile else { return false }
        do {
            let id = try await engine.restore(partialFile: package, maximumFailures: record.maximumFailures)
            return id.rawValue == record.id
        } catch {
            return false
        }
    }

    private func apply(_ snapshot: DownloadSnapshot) async {
        let id = snapshot.id
        guard var record = records[id] else { return }
        if snapshot.state == .cancelled {
            snapshots[id] = nil
            publish()
            return
        }
        snapshots[id] = snapshot

        let wasActive = record.state == .downloading
        var state = Self.storedState(for: snapshot.state)
        if record.state == .queued, state != .downloading, state != .completed { state = .queued }
        let changed = record.state != state || record.fileName != snapshot.fileName
            || record.folder != snapshot.destinationFolder || record.totalBytes != snapshot.totalBytes
            || record.wasSkipped != snapshot.wasSkipped || (record.partialFile == nil && state == .downloading)
        if changed {
            record.state = state
            record.fileName = snapshot.fileName
            record.folder = snapshot.destinationFolder
            record.totalBytes = snapshot.totalBytes
            record.receivedBytes = snapshot.receivedBytes
            record.wasSkipped = snapshot.wasSkipped
            record.isNotSecure = snapshot.isNotSecure
            record.category = FileCategory(fileName: snapshot.fileName, contentType: nil)
            if state == .completed {
                record.completedAt = now()
                record.partialFile = nil
                missingFiles.remove(id)
            } else if let package = await engine.partialFile(of: id) {
                record.partialFile = package
            }
            records[id] = record
            save(record)
        }
        publish()
        if wasActive, state != .downloading { await fillSlots() }
    }

    private static func storedState(for state: DownloadState) -> StoredDownload.State {
        switch state {
        case .probing, .downloading, .retrying, .finalizing: .downloading
        case .paused: .paused
        case .failed: .failed
        case .completed, .cancelled: .completed
        }
    }

    private func save(_ record: StoredDownload) {
        try? store.save(record)
    }

    private func publish() {
        let rows = currentRows()
        guard rows != published else { return }
        published = rows
        for observer in observers.values { observer.yield(rows) }
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func currentRows() -> [DownloadRow] {
        records.values
            .sorted { ($0.addedAt, $0.id.uuidString) > ($1.addedAt, $1.id.uuidString) }
            .map { row(for: $0) }
    }

    private func row(for record: StoredDownload) -> DownloadRow {
        let id = DownloadID(rawValue: record.id)
        let live = snapshots[id]
        return DownloadRow(
            id: id,
            state: record.state == .queued ? .queued : live.map { Self.rowState(for: $0.state) } ?? Self.rowState(for: record.state),
            fileName: live?.fileName ?? record.fileName,
            sourceURL: record.sourceURL,
            host: live?.displayHost ?? record.displayHost,
            folder: live?.destinationFolder ?? record.folder,
            category: record.category,
            receivedBytes: live?.receivedBytes ?? record.receivedBytes,
            totalBytes: live?.totalBytes ?? record.totalBytes,
            segments: live?.segments ?? [],
            activeConnections: live?.activeConnections ?? 0,
            bytesPerSecond: live?.bytesPerSecond ?? 0,
            timeRemaining: live?.timeRemaining,
            isNotSecure: live?.isNotSecure ?? record.isNotSecure,
            canResume: live?.canResume ?? false,
            addedAt: record.addedAt,
            completedAt: record.completedAt,
            isFileMissing: missingFiles.contains(id),
            wasSkipped: live?.wasSkipped ?? record.wasSkipped
        )
    }

    private static func rowState(for state: DownloadState) -> DownloadRow.State {
        switch state {
        case .probing, .downloading, .finalizing, .cancelled: .downloading
        case .retrying(let attempt, let nextTry): .retrying(attempt: attempt, nextTry: nextTry)
        case .paused: .paused
        case .failed(let error): .failed(error)
        case .completed: .completed
        }
    }

    private static func rowState(for state: StoredDownload.State) -> DownloadRow.State {
        switch state {
        case .queued: .queued
        case .paused, .downloading, .failed: .paused
        case .completed: .completed
        }
    }
}
