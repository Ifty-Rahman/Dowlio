import DowlioCore
import Foundation

/// Runs one download: probes the server, moves the bytes into the partial file over one or more
/// connections, then puts the finished file in place. Failed connections are retried. Running it
/// again after it failed continues from the bytes it has (Retry, `GLOSSARY.md`).
struct DownloadRun: Sendable {
    /// Applies a change to the download's snapshot in the engine.
    typealias ChangeSnapshot = @Sendable (@escaping @Sendable (inout DownloadSnapshot) -> Void) async -> Void

    static let progressInterval: Duration = .milliseconds(250)
    /// The manifest is saved every 4 progress ticks, about once a second.
    static let ticksPerManifestSave = 4

    let id: DownloadID
    let url: URL
    let folder: URL
    let options: RequestOptions
    let partialFile: PartialFileLocation
    let configuration: EngineConfiguration
    let changeSnapshot: ChangeSnapshot
    /// What the first run learned and wrote, kept for Retry.
    private let state = RunState()
    private let retries = RetryTracker()
    /// How many connections may be open at once. Refusals lower it.
    private let gate = ConnectionGate()

    init(
        id: DownloadID,
        url: URL,
        folder: URL,
        options: RequestOptions,
        partialFile: PartialFileLocation,
        configuration: EngineConfiguration,
        changeSnapshot: @escaping ChangeSnapshot
    ) {
        self.id = id
        self.url = url
        self.folder = folder
        self.options = options
        self.partialFile = partialFile
        self.configuration = configuration
        self.changeSnapshot = changeSnapshot
    }

    /// Runs the download. `resuming` is true when the user resumes a paused download.
    func run(resuming: Bool = false) async {
        // Kept outside `do`, so a failure still reports and saves the bytes the download has.
        var current: Prepared?
        do {
            var prepared = try await prepare(resuming: resuming)
            current = prepared
            saveManifest(prepared)
            // A file that changes on the server starts the download over once. A second change in
            // a row fails it, so bytes from two versions are never mixed.
            var startedOverForChange = false
            while true {
                let attempt = prepared
                do {
                    try await reportingProgress(of: attempt) {
                        switch attempt.layout {
                        case .whole:
                            try await receiveWhole(attempt)
                        case .ranges(let validator):
                            try await receiveSegments(attempt, validator: validator)
                        }
                    }
                    break
                } catch is FileChangedOnServer {
                    guard !startedOverForChange else { throw DownloadError.serverChangedFile }
                    startedOverForChange = true
                    let probed = try await withRetries(.probe, host: url) { try await probe(url) }
                    prepared = try await startOver(attempt, with: probed)
                    current = prepared
                    saveManifest(prepared)
                } catch is RangesUnusable {
                    // The server's range replies can't be trusted, so one connection fetches the
                    // whole file. Starting over empties the partial file, so no byte of a bad
                    // reply stays in it.
                    let whole = try await withRetries(.whole, host: attempt.finalURL) {
                        try await openWholeFile(at: attempt.finalURL)
                    }
                    prepared = try await startOver(attempt, with: whole)
                    current = prepared
                    saveManifest(prepared)
                }
            }

            let reading = prepared.board.reading
            await changeSnapshot {
                $0.apply(reading)
                $0.bytesPerSecond = 0
                $0.timeRemaining = nil
                $0.state = .finalizing
            }
            // Every byte must be present before the file goes into place.
            if let expected = prepared.totalBytes, !prepared.board.coversFile(of: expected) {
                throw DownloadError.incompleteFile
            }
            try Task.checkCancellation()
            let finished = try prepared.partial.finish(
                named: prepared.fileName, in: folder, policy: options.nameConflictPolicy, source: url
            )
            partialFile.url = nil
            await changeSnapshot {
                $0.fileName = finished.name
                $0.wasSkipped = finished.wasSkipped
                $0.state = .completed
            }
        } catch where Task.isCancelled {
            // Stopped by the engine for Pause or Cancel. The engine reports the new state. The last
            // reading goes out first, so a paused download shows exactly the bytes it keeps.
            if let current {
                saveManifest(current)
                let reading = current.board.reading
                await changeSnapshot { $0.apply(reading) }
            }
        } catch let error as DownloadError {
            await fail(with: error, current)
        } catch {
            await fail(with: .network(error.localizedDescription), current)
        }
    }

    /// Reports Failed with the progress the download keeps, so the interface shows how much is
    /// already downloaded and Retry continues from there.
    private func fail(with error: DownloadError, _ prepared: Prepared?) async {
        if let prepared { saveManifest(prepared) }
        let reading = prepared?.board.reading
        await changeSnapshot {
            if let reading { $0.apply(reading) }
            $0.bytesPerSecond = 0
            $0.timeRemaining = nil
            $0.state = .failed(error)
        }
    }

    /// Saves the partial file's manifest. The counts are read before the data file is flushed,
    /// so they never claim bytes that aren't on disk yet. A failed save keeps the previous one.
    private func saveManifest(_ prepared: Prepared) {
        let reading = prepared.board.reading
        let (layout, validator): (PartialFileManifest.Layout, String?) = switch prepared.layout {
        case .whole: (.whole, nil)
        case .ranges(let validator): (.ranges, validator)
        }
        let manifest = PartialFileManifest(
            formatVersion: PartialFileManifest.currentFormatVersion,
            downloadID: id.description,
            originalURL: url,
            finalURL: prepared.finalURL,
            validator: validator,
            totalBytes: prepared.totalBytes,
            fileName: prepared.fileName,
            connections: options.connections,
            referrer: options.referrer,
            userAgent: options.userAgent,
            segments: reading.segments.map { .init(start: $0.start, end: $0.end, received: $0.receivedBytes) },
            layout: layout
        )
        try? prepared.partial.saveManifest(manifest)
    }

    // MARK: - Preparing

    /// The probe's result and the partial file. Retry continues an earlier run's state as it is.
    /// Resume asks the server again first, because the file may have changed while paused.
    private func prepare(resuming: Bool) async throws -> Prepared {
        // A partial file deleted in the meantime, for example in Finder, means starting over in a
        // new one. The download doesn't fail for it (architecture.md, files on disk).
        if let prepared = state.prepared, prepared.partial.isMissing {
            state.forget()
            partialFile.url = nil
        }
        if let prepared = state.prepared {
            if resuming { return try await revalidate(prepared) }
            await changeSnapshot { $0.state = .downloading }
            return prepared
        }

        let probed = try await withRetries(.probe, host: url) { try await probe(url) }
        let fileName = FileNaming.name(for: probed.probeResponse, finalURL: probed.finalURL)
        await changeSnapshot {
            $0.state = .downloading
            $0.fileName = fileName
            $0.totalBytes = probed.totalBytes
            $0.isNotSecure = probed.finalURL.isPlainHTTP || url.isPlainHTTP
        }

        let partial = try PartialFile.create(for: fileName, in: folder)
        partialFile.url = partial.packageURL
        let prepared = try layOut(probed, fileName: fileName, in: partial)
        await changeSnapshot { $0.canResume = prepared.canResume }
        return prepared
    }

    /// On Resume, requests the original link again, because signed final links expire
    /// (architecture.md, resume). The download keeps its segments only if the server still has the
    /// same file: same size and the same validator. Otherwise it starts over in the same partial file.
    private func revalidate(_ prepared: Prepared) async throws -> Prepared {
        let probed = try await probeForResume(prepared)
        if case .ranges(let total, let validator?) = probed.body,
           case .ranges(let saved?) = prepared.layout,
           total == prepared.totalBytes, validator == saved {
            var kept = prepared
            kept.finalURL = probed.finalURL
            state.store(kept, probeConnection: nil)
            await changeSnapshot { $0.state = .downloading }
            return kept
        }

        return try await startOver(prepared, with: probed)
    }

    /// Empties the partial file and lays the download out again from `probed`, for a file that
    /// changed on the server or can't be checked. The finished file keeps its planned name.
    private func startOver(_ prepared: Prepared, with probed: Probed) async throws -> Prepared {
        try prepared.partial.discardData()
        let restarted = try layOut(probed, fileName: prepared.fileName, in: prepared.partial)
        let reading = restarted.board.reading
        await changeSnapshot {
            $0.state = .downloading
            $0.totalBytes = restarted.totalBytes
            $0.canResume = restarted.canResume
            $0.apply(reading)
        }
        return restarted
    }

    /// Probes the original link. If it's gone (403, 404, 410), probes the last final link, which
    /// may still work for a while. If both are gone, the link has expired.
    private func probeForResume(_ prepared: Prepared) async throws -> Probed {
        do {
            return try await withRetries(.probe, host: url) { try await probe(url) }
        } catch let error as DownloadError where Self.meansLinkGone(error) {
            do {
                return try await withRetries(.probe, host: prepared.finalURL) { try await probe(prepared.finalURL) }
            } catch let error as DownloadError where Self.meansLinkGone(error) {
                throw DownloadError.linkExpired
            }
        }
    }

    private static func meansLinkGone(_ error: DownloadError) -> Bool {
        error == .forbidden || error == .notFound
    }

    /// Plans the segments for what `probed` found and reserves the space, before any of the file's
    /// bytes are requested.
    private func layOut(_ probed: Probed, fileName: String, in partial: PartialFile) throws -> Prepared {
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
            let hostLimit = probed.finalURL.hostLimitKey.flatMap(configuration.hostLimits.limit(for:))
            gate.setLimit(min(options.connections, hostLimit ?? .max))
            let segments = SegmentPlanner.plan(size: total, connections: options.connections, hostLimit: hostLimit)
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
        try await withRetries(.whole, host: prepared.finalURL) {
            let connection: Connection
            if let probeConnection = state.takeProbeConnection() {
                connection = probeConnection
            } else {
                try prepared.partial.discardData()
                board.reset()
                if let total = prepared.totalBytes { try prepared.partial.reserve(bytes: total) }
                connection = Connection(request: request(for: prepared.finalURL, range: nil), idleTimeout: configuration.idleTimeout)
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
        let unfinished = (0..<board.segmentCount).filter { index in
            board.received(segment: index) < board.range(segment: index).length
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
                    // A connection that finishes its segment steals half of the largest remaining
                    // part and keeps going, until nothing is left to steal.
                    var current = index
                    while true {
                        try await withRetries(.segment(current), host: prepared.finalURL) {
                            // A connection opens only while the download is under its limit. A
                            // refused one lowers the limit as it gives back its place, in one
                            // step, so a waiting connection can't take the place in between.
                            try await gate.acquire()
                            do {
                                try await receive(
                                    segment: current, of: prepared, total: total, validator: validator, onData: onData
                                )
                            } catch {
                                gate.release(lowering: Self.retryable(error)?.isRefusal == true)
                                throw error
                            }
                            gate.release()
                        }
                        guard let stolen = board.steal() else { return }
                        current = stolen
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
            // The first connection that fails for good stops every other one. `waitForAll` would
            // wait for the others to finish before rethrowing, and doesn't cancel them; leaving the
            // group by throwing does.
            for try await _ in group {}
        }
    }

    /// Fetches the part of one segment that isn't downloaded yet, and writes it at its own offset.
    /// When another connection steals the segment's end, this one writes up to the new end and
    /// closes its connection there, instead of asking the server again.
    private func receive(
        segment index: Int,
        of prepared: Prepared,
        total: Int64,
        validator: String?,
        onData: @Sendable () -> Void
    ) async throws {
        let board = prepared.board
        let segment = board.range(segment: index)
        let missing = ByteRange(start: segment.start + board.received(segment: index), end: segment.end)
        guard missing.start <= missing.end else { return }

        var request = request(for: prepared.finalURL, range: missing)
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        let connection = Connection(request: request, idleTimeout: configuration.idleTimeout)
        board.setActive(true, segment: index)
        defer { board.setActive(false, segment: index) }

        let response: HTTPURLResponse
        do {
            response = try await connection.firstResponse()
        } catch let error as URLError where error.code == .cannotDecodeRawData || error.code == .cannotDecodeContentData {
            // The reply came encoded although the request asked for identity, and URLSession
            // failed to decode it before handing over the response.
            throw RangesUnusable()
        }
        guard response.statusCode == 206 else {
            connection.cancel()
            guard response.statusCode == 200 else { throw failure(for: response) }
            // A 200 to a request with If-Range means the validator no longer matches: the file
            // changed on the server. Without a validator, the server just ignored the range.
            throw validator == nil ? RangesUnusable() : FileChangedOnServer()
        }
        guard Self.isUsableRangeReply(response), ContentRange(response) == ContentRange(range: missing, total: total) else {
            connection.cancel()
            throw RangesUnusable()
        }
        var offset = missing.start
        for try await event in connection.events {
            guard case .data(let data) = event else { continue }
            let allowed = board.claim(Int64(data.count), at: offset, segment: index)
            if allowed > 0 {
                try prepared.partial.write(data.prefix(Int(allowed)), at: offset)
                offset += allowed
                board.add(allowed, to: index)
                onData()
            }
            // Reached the segment's end, which may have moved earlier through stealing.
            if allowed < Int64(data.count) || offset > board.range(segment: index).end {
                connection.cancel()
                return
            }
        }
        try Task.checkCancellation()
        // The connection ended cleanly but early.
        if offset <= board.range(segment: index).end { throw RetryableFailure() }
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
    private func withRetries<T: Sendable>(_ key: RetryKey, host: URL, _ work: () async throws -> T) async throws -> T {
        let policy = configuration.retry
        var failures = 0
        while true {
            do {
                return try await work()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard let retryable = Self.retryable(error) else { throw error }
                if retryable.isRefusal { lowerLimit(of: host) }
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
        if let error = error as? URLError, error.code.isRetryable {
            // A reset connection counts as a refusal (spec, retry policy).
            return RetryableFailure(isRefusal: error.code == .networkConnectionLost)
        }
        return nil
    }

    /// After a refusal, every later download from `host` gets one connection fewer. A refused
    /// segment connection has already lowered this download's own limit.
    private func lowerLimit(of host: URL) {
        guard let key = host.hostLimitKey else { return }
        let connections = options.connections
        configuration.hostLimits.updateLimit(for: key) { SegmentPlanner.lowered($0 ?? connections) }
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
                retryAfter: RetryAfter.parse(response.value(forHTTPHeaderField: "Retry-After"), now: configuration.now()),
                isRefusal: response.statusCode == 429 || response.statusCode == 503
            )
        default: DownloadError.network("The server answered with status \(response.statusCode).")
        }
    }

    // MARK: - Progress

    /// Runs `work` while publishing the board at most 4 times a second, also while no bytes
    /// arrive, with speed smoothed over 5 seconds and the time left. Saves the manifest about once
    /// a second.
    private func reportingProgress(of prepared: Prepared, _ work: () async throws -> Void) async throws {
        let board = prepared.board
        let total = prepared.totalBytes
        let reporter = Task {
            var meter = SpeedMeter()
            // The starting sample lets the first tick measure bytes that arrived before it.
            _ = meter.record(board.reading.receivedBytes, at: .now)
            var published: (reading: ProgressBoard.Reading, speed: Int64)?
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                ticks += 1
                if ticks.isMultiple(of: Self.ticksPerManifestSave) { saveManifest(prepared) }
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
    private func probe(_ target: URL) async throws -> Probed {
        let probe = Connection(request: request(for: target, range: ByteRange(start: 0, end: 0)), idleTimeout: configuration.idleTimeout)
        let response = try await probe.firstResponse()
        let finalURL = response.url ?? target
        switch response.statusCode {
        case 200:
            let total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            return Probed(body: .whole(probe), finalURL: finalURL, totalBytes: total, probeResponse: response)
        case 206:
            probe.cancel()
            // A range reply that can't be used means one connection for the whole file.
            guard Self.isUsableRangeReply(response), let reply = ContentRange(response), reply.start == 0, reply.end == 0 else {
                return try await openWholeFile(at: finalURL)
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

    /// A range reply carries the file's own bytes: no `Content-Encoding` other than identity, and
    /// not `multipart/byteranges` (architecture.md, validate).
    private static func isUsableRangeReply(_ response: HTTPURLResponse) -> Bool {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased()
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let plain = encoding == nil || encoding == "identity"
        return plain && !type.hasPrefix("multipart/byteranges")
    }

    /// Asks for the whole file without a range, for a server whose range replies can't be used.
    private func openWholeFile(at target: URL) async throws -> Probed {
        let connection = Connection(request: request(for: target, range: nil), idleTimeout: configuration.idleTimeout)
        let response = try await connection.firstResponse()
        guard response.statusCode == 200 else {
            connection.cancel()
            throw failure(for: response)
        }
        let total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        return Probed(body: .whole(connection), finalURL: response.url ?? target, totalBytes: total, probeResponse: response)
    }

    /// A strong `ETag`, or else `Last-Modified`. A weak ETag can't be used with `If-Range`.
    private static func validator(of response: HTTPURLResponse) -> String? {
        if let tag = response.value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/") {
            return tag
        }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }

    /// A request for `range` of the file, or for the whole file when `range` is `nil`, with the
    /// download's referrer and user agent.
    private func request(for url: URL, range: ByteRange?) -> URLRequest {
        var request = URLRequest(url: url)
        if let range { request.setValue(range.headerValue, forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let referrer = options.referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
        if let userAgent = options.userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        return request
    }
}

extension DownloadRun {
    /// Continues from a restored partial file instead of probing first. Resume then revalidates
    /// it with the server, as for any paused download.
    func adopt(_ prepared: Prepared) {
        partialFile.url = prepared.partial.packageURL
        state.store(prepared, probeConnection: nil)
    }
}

/// A segment request's validator no longer matched, so the file changed on the server.
struct FileChangedOnServer: Error {}

/// A range reply that can't be used, so the download falls back to one connection (spec,
/// connections).
struct RangesUnusable: Error {}

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
    var finalURL: URL
    let totalBytes: Int64?
    let layout: Layout
    let segments: [ByteRange]
    let partial: PartialFile
    let board: ProgressBoard

    /// Pausing keeps the bytes only when the server supports ranges, the size is known, and a
    /// strong validator lets a resume check that the file hasn't changed. Without one, a resume
    /// starts over.
    var canResume: Bool {
        if case .ranges(_?) = layout, totalBytes != nil { true } else { false }
    }
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

    /// Drops the prepared state, so the next run starts the download as new.
    func forget() {
        lock.withLock {
            stored = nil
            probeConnection = nil
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
