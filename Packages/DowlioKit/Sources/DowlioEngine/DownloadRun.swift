import DowlioCore
import Foundation

/// Runs one download: probes the server, moves the bytes into the partial file over one or more
/// connections, then puts the finished file in place. Failed connections are retried. Running it
/// again after it failed continues from the bytes it has (Retry, `GLOSSARY.md`).
struct DownloadRun: Sendable {
    /// Applies a change to the download's snapshot in the engine.
    typealias ChangeSnapshot = @Sendable (@escaping @Sendable (inout DownloadSnapshot) -> Void) async -> Void

    static let progressInterval: Duration = .milliseconds(250)

    let url: URL
    let folder: URL
    let options: RequestOptions
    let partialFile: PartialFileLocation
    let configuration: EngineConfiguration
    let changeSnapshot: ChangeSnapshot
    /// What the first run learned and wrote, kept for Retry.
    private let state = RunState()
    private let retries = RetryTracker()

    init(
        url: URL,
        folder: URL,
        options: RequestOptions,
        partialFile: PartialFileLocation,
        configuration: EngineConfiguration,
        changeSnapshot: @escaping ChangeSnapshot
    ) {
        self.url = url
        self.folder = folder
        self.options = options
        self.partialFile = partialFile
        self.configuration = configuration
        self.changeSnapshot = changeSnapshot
    }

    func run() async {
        do {
            let prepared = try await prepare()
            try await reportingProgress(of: prepared.board, total: prepared.totalBytes) {
                switch prepared.layout {
                case .whole:
                    try await receiveWhole(prepared)
                case .ranges(let validator):
                    try await receiveSegments(prepared, validator: validator)
                }
            }

            let board = prepared.board
            let reading = board.reading
            await changeSnapshot {
                $0.apply(reading)
                $0.bytesPerSecond = 0
                $0.timeRemaining = nil
                $0.state = .finalizing
            }
            // Every byte must be present before the file goes into place.
            if let expected = prepared.totalBytes,
               reading.receivedBytes != expected || (!reading.segments.isEmpty && !board.coversEverySegment) {
                throw DownloadError.incompleteFile
            }
            try Task.checkCancellation()
            let finishedName = try prepared.partial.finish(
                named: prepared.fileName, in: folder, policy: options.nameConflictPolicy, source: url
            )
            partialFile.url = nil
            await changeSnapshot { $0.fileName = finishedName; $0.state = .completed }
        } catch where Task.isCancelled {
            // Cancelled by the engine, which deletes the partial file and reports Cancelled.
        } catch let error as DownloadError {
            await changeSnapshot { $0.state = .failed(error) }
        } catch {
            let description = error.localizedDescription
            await changeSnapshot { $0.state = .failed(.network(description)) }
        }
    }

    // MARK: - Preparing

    /// The probe's result and the partial file, from this run or from an earlier one that failed.
    private func prepare() async throws -> Prepared {
        if let prepared = state.prepared {
            await changeSnapshot { $0.state = .downloading }
            return prepared
        }

        let probed = try await withRetries(.probe) { try await probe() }
        let fileName = FileNaming.name(for: probed.probeResponse, finalURL: probed.finalURL)
        await changeSnapshot {
            $0.state = .downloading
            $0.fileName = fileName
            $0.totalBytes = probed.totalBytes
            $0.isNotSecure = probed.finalURL.isPlainHTTP || url.isPlainHTTP
        }

        // The space is reserved before any of the file's bytes are requested.
        let partial = try PartialFile.create(for: fileName, in: folder)
        partialFile.url = partial.packageURL
        if let total = probed.totalBytes { try partial.reserve(bytes: total) }

        let prepared: Prepared
        switch probed.body {
        case .whole(let connection):
            let segments = probed.totalBytes.map { [ByteRange(start: 0, end: $0 - 1)] } ?? []
            prepared = Prepared(
                fileName: fileName, finalURL: probed.finalURL, totalBytes: probed.totalBytes,
                layout: .whole, segments: segments, partial: partial, board: ProgressBoard(segments: segments)
            )
            state.store(prepared, probeConnection: connection)
        case .ranges(let total, let validator):
            let segments = SegmentPlanner.plan(size: total, connections: options.connections)
            prepared = Prepared(
                fileName: fileName, finalURL: probed.finalURL, totalBytes: total,
                layout: .ranges(validator: validator), segments: segments, partial: partial,
                board: ProgressBoard(segments: segments)
            )
            state.store(prepared, probeConnection: nil)
        }
        return prepared
    }

    // MARK: - Receiving

    /// Reads the whole file from a server that doesn't support ranges. It can't resume, so every
    /// retry starts the file over.
    private func receiveWhole(_ prepared: Prepared) async throws {
        let board = prepared.board
        let segmented = !prepared.segments.isEmpty
        try await withRetries(.whole) {
            let connection: Connection
            if let probeConnection = state.takeProbeConnection() {
                connection = probeConnection
            } else {
                try prepared.partial.discardData()
                board.reset()
                if let total = prepared.totalBytes { try prepared.partial.reserve(bytes: total) }
                connection = Connection(request: Self.request(for: prepared.finalURL, range: nil), idleTimeout: configuration.idleTimeout)
                let response = try await connection.firstResponse()
                guard response.statusCode == 200 else {
                    connection.cancel()
                    throw failure(for: response)
                }
            }

            if segmented { board.setActive(true, segment: 0) }
            defer { if segmented { board.setActive(false, segment: 0) } }
            for try await event in connection.events {
                if case .data(let data) = event {
                    try prepared.partial.append(data)
                    board.add(Int64(data.count), to: segmented ? 0 : nil)
                }
            }
            try Task.checkCancellation()
            // The connection ended cleanly but early.
            if let total = prepared.totalBytes, board.reading.receivedBytes < total {
                throw RetryableFailure()
            }
        }
    }

    /// Fetches every unfinished segment over its own connection. The first connection opens alone.
    /// The others open once it receives data, or at once in "all at once" mode.
    private func receiveSegments(_ prepared: Prepared, validator: String?) async throws {
        let board = prepared.board
        let unfinished = prepared.segments.indices.filter { index in
            board.received(segment: index) < prepared.segments[index].length
        }
        guard let first = unfinished.first, let total = prepared.totalBytes else { return }

        let firstData = OneShot()
        try await withThrowingTaskGroup(of: Void.self) { group in
            func fetch(_ index: Int) {
                // The first connection fires the signal on its first data, or when it ends.
                let onData: @Sendable () -> Void
                if index == first {
                    onData = { firstData.fire() }
                } else {
                    onData = {}
                }
                group.addTask {
                    defer { if index == first { firstData.fire() } }
                    try await withRetries(.segment(index)) {
                        try await receive(
                            segment: index, of: prepared, total: total, validator: validator, onData: onData
                        )
                    }
                }
            }

            fetch(first)
            if options.openExtraConnections == .afterFirstConnectionStarts {
                await firstData.wait()
            }
            for index in unfinished.dropFirst() where !Task.isCancelled {
                fetch(index)
            }
            try await group.waitForAll()
        }
    }

    /// Fetches the part of one segment that isn't downloaded yet, and writes it at its own offset.
    private func receive(
        segment index: Int,
        of prepared: Prepared,
        total: Int64,
        validator: String?,
        onData: @Sendable () -> Void
    ) async throws {
        let segment = prepared.segments[index]
        let board = prepared.board
        let missing = ByteRange(start: segment.start + board.received(segment: index), end: segment.end)
        guard missing.start <= missing.end else { return }

        var request = Self.request(for: prepared.finalURL, range: missing)
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        let connection = Connection(request: request, idleTimeout: configuration.idleTimeout)
        board.setActive(true, segment: index)
        defer { board.setActive(false, segment: index) }

        let response = try await connection.firstResponse()
        guard response.statusCode == 206 else {
            connection.cancel()
            // A 200 to a ranged request means the server sent the whole file instead.
            throw response.statusCode == 200 ? DownloadError.rangeNotSupported : failure(for: response)
        }
        guard ContentRange(response) == ContentRange(range: missing, total: total) else {
            connection.cancel()
            throw DownloadError.rangeNotSupported
        }
        var offset = missing.start
        for try await event in connection.events {
            guard case .data(let data) = event else { continue }
            try prepared.partial.write(data, at: offset)
            offset += Int64(data.count)
            board.add(Int64(data.count), to: index)
            onData()
        }
        try Task.checkCancellation()
        // The connection ended cleanly but early.
        if offset <= missing.end { throw RetryableFailure() }
    }

    // MARK: - Retrying

    /// What a retry is for. Several segments can wait at the same time.
    enum RetryKey: Hashable {
        case probe
        case whole
        case segment(Int)
    }

    /// Runs `work`, and runs it again after a wait while it fails in a way worth retrying. The
    /// download shows Retrying while it waits. After the policy's maximum failures in a row it
    /// throws `DownloadError.tooManyRetries`.
    private func withRetries<T: Sendable>(_ key: RetryKey, _ work: () async throws -> T) async throws -> T {
        let policy = configuration.retry
        var failures = 0
        while true {
            do {
                return try await work()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard let retryable = Self.retryable(error) else { throw error }
                failures += 1
                guard failures < policy.maximumFailures else { throw DownloadError.tooManyRetries }

                let delay = policy.delay(afterFailure: failures, retryAfter: retryable.retryAfter, random: configuration.random)
                retries.begin(key, attempt: failures, nextTry: configuration.now().addingTimeInterval(delay.timeInterval))
                await publishRetryState()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    retries.end(key)
                    throw error
                }
                retries.end(key)
                await publishRetryState()
            }
        }
    }

    private static func retryable(_ error: Error) -> RetryableFailure? {
        if let retryable = error as? RetryableFailure { return retryable }
        if let error = error as? URLError, error.code.isRetryable { return RetryableFailure() }
        return nil
    }

    /// Shows Retrying while any connection waits, and Downloading again once none does.
    private func publishRetryState() async {
        let retries = retries
        await changeSnapshot { snapshot in
            switch snapshot.state {
            case .probing, .downloading, .retrying:
                snapshot.state = retries.state ?? .downloading
            default:
                break
            }
        }
    }

    /// The error a reply that isn't the file stands for: a refusal, or a busy server to retry.
    private func failure(for response: HTTPURLResponse) -> Error {
        switch response.statusCode {
        case 401: DownloadError.needsSignIn
        case 403: DownloadError.forbidden
        case 404, 410: DownloadError.notFound
        case 408, 429, 500...599:
            RetryableFailure(
                retryAfter: RetryAfter.parse(response.value(forHTTPHeaderField: "Retry-After"), now: configuration.now())
            )
        default: DownloadError.network("The server answered with status \(response.statusCode).")
        }
    }

    // MARK: - Progress

    /// Runs `work` while publishing the board at most 4 times a second, also while no bytes
    /// arrive, with speed smoothed over 5 seconds and the time left.
    private func reportingProgress(of board: ProgressBoard, total: Int64?, _ work: () async throws -> Void) async throws {
        let reporter = Task {
            var meter = SpeedMeter()
            // The starting sample lets the first tick measure bytes that arrived before it.
            _ = meter.record(board.reading.receivedBytes, at: .now)
            var published: (reading: ProgressBoard.Reading, speed: Int64)?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                let reading = board.reading
                let speed = meter.record(reading.receivedBytes, at: .now)
                if let published, published.reading == reading, published.speed == speed { continue }
                published = (reading, speed)
                let remaining: TimeInterval? = total.flatMap { total in
                    speed > 0 ? TimeInterval(total - reading.receivedBytes) / TimeInterval(speed) : nil
                }
                await changeSnapshot {
                    $0.apply(reading)
                    $0.bytesPerSecond = speed
                    $0.timeRemaining = remaining
                }
            }
        }
        defer { reporter.cancel() }
        try await work()
    }

    // MARK: - Probe

    private enum ProbedBody {
        /// The probe's own 200 response, which carries the whole file.
        case whole(Connection)
        /// The server supports ranges.
        case ranges(total: Int64, validator: String?)
    }

    private struct Probed {
        let body: ProbedBody
        let finalURL: URL
        let totalBytes: Int64?
        /// The probe's response, whose headers name the file.
        let probeResponse: HTTPURLResponse
    }

    /// Sends `Range: bytes=0-0` (architecture.md, probe). A 206 means the server supports ranges
    /// and gives the size. A 200 means it doesn't, and the probe's own response is the download.
    private func probe() async throws -> Probed {
        let probe = Connection(request: Self.request(for: url, range: ByteRange(start: 0, end: 0)), idleTimeout: configuration.idleTimeout)
        let response = try await probe.firstResponse()
        let finalURL = response.url ?? url
        switch response.statusCode {
        case 200:
            let total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            return Probed(body: .whole(probe), finalURL: finalURL, totalBytes: total, probeResponse: response)
        case 206:
            probe.cancel()
            guard let reply = ContentRange(response), reply.start == 0, reply.end == 0 else {
                throw DownloadError.rangeNotSupported
            }
            return Probed(
                body: .ranges(total: reply.total, validator: Self.validator(of: response)),
                finalURL: finalURL,
                totalBytes: reply.total,
                probeResponse: response
            )
        default:
            probe.cancel()
            throw failure(for: response)
        }
    }

    /// A strong `ETag`, or else `Last-Modified`. A weak ETag can't be used with `If-Range`.
    private static func validator(of response: HTTPURLResponse) -> String? {
        if let tag = response.value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/") {
            return tag
        }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }

    /// A request for `range` of the file, or for the whole file when `range` is `nil`.
    private static func request(for url: URL, range: ByteRange?) -> URLRequest {
        var request = URLRequest(url: url)
        if let range { request.setValue(range.headerValue, forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

// MARK: - Run state

/// What a download learned from its probe and where its bytes go.
struct Prepared: Sendable {
    enum Layout: Sendable {
        /// One connection reads the whole file. The server can't resume.
        case whole
        /// Segments over several connections, each request checked against `validator`.
        case ranges(validator: String?)
    }

    let fileName: String
    let finalURL: URL
    let totalBytes: Int64?
    let layout: Layout
    let segments: [ByteRange]
    let partial: PartialFile
    let board: ProgressBoard
}

/// A download's prepared state, kept between a run that failed and the Retry that continues it.
final class RunState: @unchecked Sendable {
    // @unchecked: both stored properties are only read or written under `lock`.
    private let lock = NSLock()
    private var stored: Prepared?
    private var probeConnection: Connection?

    var prepared: Prepared? { lock.withLock { stored } }

    func store(_ prepared: Prepared, probeConnection: Connection?) {
        lock.withLock {
            stored = prepared
            self.probeConnection = probeConnection
        }
    }

    /// The probe's own connection, which carries the whole file. Only the first try may read it.
    func takeProbeConnection() -> Connection? {
        lock.withLock {
            defer { probeConnection = nil }
            return probeConnection
        }
    }
}

/// Which parts of a download are waiting to retry, and until when.
final class RetryTracker: @unchecked Sendable {
    // @unchecked: `waits` is only read or written under `lock`.
    private let lock = NSLock()
    private var waits: [DownloadRun.RetryKey: (attempt: Int, nextTry: Date)] = [:]

    func begin(_ key: DownloadRun.RetryKey, attempt: Int, nextTry: Date) {
        lock.withLock { waits[key] = (attempt, nextTry) }
    }

    func end(_ key: DownloadRun.RetryKey) {
        _ = lock.withLock { waits.removeValue(forKey: key) }
    }

    /// Retrying with the highest attempt and the earliest next try, or `nil` while nothing waits.
    var state: DownloadState? {
        lock.withLock {
            guard let attempt = waits.values.map(\.attempt).max(),
                  let nextTry = waits.values.map(\.nextTry).min() else { return nil }
            return .retrying(attempt: attempt, nextTry: nextTry)
        }
    }
}

extension DownloadSnapshot {
    mutating func apply(_ reading: ProgressBoard.Reading) {
        segments = reading.segments
        receivedBytes = reading.receivedBytes
        activeConnections = reading.activeConnections
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// A signal that fires once. Waiters resume when it fires, and wait no longer after that.
final class OneShot: @unchecked Sendable {
    // @unchecked: `fired` and `waiters` are only read or written under `lock`.
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !fired else { return [] }
            fired = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// An inclusive byte range, as HTTP writes it.
struct ByteRange: Equatable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { end - start + 1 }

    /// The `Range` request header value.
    var headerValue: String { "bytes=\(start)-\(end)" }
}

/// A parsed `Content-Range: bytes start-end/total` header.
struct ContentRange: Equatable {
    let range: ByteRange
    let total: Int64

    var start: Int64 { range.start }
    var end: Int64 { range.end }

    init(range: ByteRange, total: Int64) {
        self.range = range
        self.total = total
    }

    init?(_ response: HTTPURLResponse) {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        self.init(value)
    }

    init?(_ value: String) {
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst("bytes ".count).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start <= end, end < total else { return nil }
        self.init(range: ByteRange(start: start, end: end), total: total)
    }
}
