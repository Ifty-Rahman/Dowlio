import DowlioCore
import Foundation

extension DownloadRun {
    func runMedia(_ media: MediaSource, resuming: Bool) async {
        var current: MediaPlan?
        do {
            var plan = try await prepareMedia(media)
            current = plan
            if plan.media.renewal?.needsListing == true {
                guard canRenew(plan) else { throw DownloadError.needsTools }
                plan = try await renewing(plan)
                current = plan
            }
            if plan.media.downloadsWithYTDLP {
                saveManifest(plan)
                return try await downloadWithYTDLP(plan)
            }
            if canRenew(plan), Self.isExpiring(plan.media, at: configuration.now()) {
                plan = try await renewingBeforeStart(plan)
                current = plan
            }
            saveManifest(plan)
            plan = try await receivingWithOneRenewal(plan, resuming: resuming) { current = $0 }
            try await finish(plan)
        } catch where Task.isCancelled {
            if let current {
                saveManifest(current)
                let reading = current.reading
                await changeSnapshot { $0.apply(reading) }
            }
        } catch let error as DownloadError {
            await fail(with: error, current)
        } catch {
            await fail(with: .network(NetworkFailure(error)), current)
        }
    }

    func adopt(_ plan: MediaPlan) {
        partialFile.url = plan.partial.packageURL
        mediaPlans.store(plan)
    }

    private func prepareMedia(_ media: MediaSource) async throws -> MediaPlan {
        if let plan = mediaPlans.plan, plan.partial.isMissing {
            mediaPlans.forget()
            partialFile.url = nil
        }
        applyHostLimit(of: url)
        if let plan = mediaPlans.plan {
            await changeSnapshot { $0.state = .downloading }
            return plan
        }

        let fileName = options.fileName.map(FileNaming.chosen) ?? Self.mediaFileName(for: url, of: media)
        let contentType = media.contentType
        let folder = Self.folder(destination.folder(forFileNamed: fileName, contentType: contentType), within: options.subfolder)
        let category = FileCategory(fileName: fileName, contentType: contentType)
        let isNotSecure = media.tracks.contains { track in
            (track.fragments + (track.initialization.map { [$0] } ?? [])).contains { $0.url.isPlainHTTP }
        }
        await changeSnapshot {
            $0.state = .downloading
            $0.fileName = fileName
            $0.category = category
            $0.destinationFolder = folder
            $0.isNotSecure = isNotSecure
            $0.canResume = true
        }
        if folder != destination.root {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw DownloadError.destinationNotWritable
            }
        }
        let partial = try PartialFile.create(for: fileName, in: folder)
        let plan = MediaPlan(fileName: fileName, media: media, partial: partial, requestSizeLimit: options.requestSizeLimit ?? media.requestSizeLimit)
        adopt(plan)
        do {
            try FileManager.default.createDirectory(at: plan.partsFolder, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.destinationNotWritable
        }
        return plan
    }

    static func folder(_ folder: URL, within subfolder: String?) -> URL {
        guard let subfolder, !FileNaming.chosen(subfolder).isEmpty else { return folder }
        return folder.appending(path: FileNaming.chosen(subfolder), directoryHint: .isDirectory)
    }

    static func mediaFileName(for url: URL, of media: MediaSource) -> String {
        let (base, _) = FileNaming.split(FileNaming.name(for: url))
        return "\(base).\(media.fileExtension)"
    }

    private func receivePieces(of plan: MediaPlan, resuming: Bool) async throws {
        let waiting = plan.waiting
        let queue = PieceQueue(waiting)
        let workers = min(connectionSetting, waiting.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    while let piece = queue.next() {
                        do {
                            try await withRetries(.fragment(piece.position), host: piece.fragment.url) {
                                try await gate.acquire()
                                do {
                                    try await receive(piece, of: plan)
                                } catch {
                                    gate.release(lowering: RetryableFailure(classifying: error)?.isRefusal == true)
                                    throw error
                                }
                                gate.release()
                            }
                        } catch let error as DownloadError where resuming && Self.meansMediaLinkGone(error) {
                            throw DownloadError.linkExpired
                        }
                    }
                }
            }
            for try await _ in group {}
        }
    }

    private static func meansMediaLinkGone(_ error: DownloadError) -> Bool {
        error == .forbidden || error == .needsSignIn
    }

    private func receivingWithOneRenewal(
        _ start: MediaPlan, resuming: Bool, adopted: (MediaPlan) -> Void
    ) async throws -> MediaPlan {
        do {
            try await reportingProgress(of: start) { try await receivePieces(of: start, resuming: resuming) }
            return start
        } catch let error as DownloadError where !Task.isCancelled && canRenew(start) && Self.asksForFreshLinks(error) {
            let renewed = try await renewing(start)
            adopted(renewed)
            try await reportingProgress(of: renewed) { try await receivePieces(of: renewed, resuming: resuming) }
            return renewed
        }
    }

    private func downloadWithYTDLP(_ plan: MediaPlan) async throws {
        guard let download = configuration.downloadWithYTDLP else { throw DownloadError.needsTools }
        let latest = LatestProgress()
        let request = YTDLPDownload(media: plan.media, folder: plan.partial.packageURL.appending(path: "yt-dlp", directoryHint: .isDirectory)) { progress in
            latest.set(progress)
        }
        let reporter = Task {
            while !Task.isCancelled {
                if let progress = latest.take() { await show(progress) }
                try? await Task.sleep(for: Self.progressInterval)
            }
        }
        defer { reporter.cancel() }
        var output: URL
        do {
            output = try await download(request)
        } catch RenewalFailure.toolsMissing {
            throw DownloadError.needsTools
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.network(NetworkFailure(error))
        }
        reporter.cancel()
        if let progress = latest.take() { await show(progress) }
        try Task.checkCancellation()
        await changeSnapshot {
            $0.bytesPerSecond = 0
            $0.timeRemaining = nil
            $0.state = .finalizing
        }
        output = await addingExtras(to: output, of: plan)
        try Task.checkCancellation()
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? nil
        let finished = try plan.partial.finish(
            named: plan.fileName, in: plan.partial.packageURL.deletingLastPathComponent(),
            policy: options.nameConflictPolicy, source: url, replacingDataWith: output
        )
        partialFile.url = nil
        mediaPlans.forget()
        await changeSnapshot {
            if let size {
                $0.receivedBytes = size
                $0.totalBytes = size
            }
            $0.fileName = finished.name
            $0.wasSkipped = finished.wasSkipped
            $0.state = .completed
        }
    }

    private func addingExtras(to output: URL, of plan: MediaPlan) async -> URL {
        guard plan.media.extras != nil, let remux = configuration.remux else { return output }
        let extras = await fetchExtras(of: plan)
        let joined = plan.partial.packageURL.appending(path: "with-extras.\(output.pathExtension)")
        let request = RemuxRequest(
            tracks: [output], output: joined, mediaSource: plan.media, subtitles: extras.subtitles,
            chapters: plan.media.extras?.chapters ?? [], coverArt: extras.coverArt
        )
        guard request.hasExtras, !Task.isCancelled else { return output }
        do {
            try await remux(request)
            return joined
        } catch {
            return output
        }
    }

    private func show(_ progress: YTDLPProgress) async {
        await changeSnapshot {
            $0.receivedBytes = progress.receivedBytes
            $0.totalBytes = progress.totalBytes
            $0.bytesPerSecond = progress.bytesPerSecond
            $0.timeRemaining = progress.secondsLeft
            $0.activeConnections = 1
            let whole = progress.totalBytes.map {
                [SegmentProgress(start: 0, end: max($0 - 1, 0), receivedBytes: min(progress.receivedBytes, $0), isActive: true)]
            } ?? []
            $0.segments = whole
            $0.plannedSegments = whole.map { SegmentBounds(start: $0.start, end: $0.end) }
        }
    }

    private func renewingBeforeStart(_ plan: MediaPlan) async throws -> MediaPlan {
        do {
            return try await renewing(plan)
        } catch DownloadError.needsTools {
            throw DownloadError.needsTools
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch {
            return plan
        }
    }

    static let renewalMargin: TimeInterval = 5 * 60

    static func isExpiring(_ media: MediaSource, at now: Date) -> Bool {
        guard let expiry = media.expiry else { return false }
        return expiry.timeIntervalSince(now) < renewalMargin
    }

    private static func asksForFreshLinks(_ error: DownloadError) -> Bool {
        [.linkExpired, .forbidden, .notFound, .needsSignIn].contains(error)
    }

    private func canRenew(_ plan: MediaPlan) -> Bool {
        configuration.renew != nil && plan.media.renewal != nil
    }

    private func renewing(_ plan: MediaPlan) async throws -> MediaPlan {
        guard let renew = configuration.renew else { return plan }
        let fresh: MediaSource
        do {
            fresh = try await renew(plan.media)
        } catch RenewalFailure.toolsMissing {
            throw DownloadError.needsTools
        } catch let error as DownloadError {
            throw error
        } catch RenewalFailure.needsSignIn {
            throw DownloadError.needsSignIn
        } catch RenewalFailure.network {
            throw DownloadError.network(NetworkFailure(code: .notConnectedToInternet, message: "Couldn't reach the page for fresh links"))
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch {
            throw DownloadError.linkExpired
        }
        try Task.checkCancellation()
        let keepsParts = Self.sameLayout(plan.media, fresh)
        let (base, _) = FileNaming.split(plan.fileName)
        let fileName = fresh.fileExtension == plan.media.fileExtension ? plan.fileName : "\(base).\(fresh.fileExtension)"
        let next = MediaPlan(
            fileName: fileName, media: fresh, partial: plan.partial, requestSizeLimit: options.requestSizeLimit ?? fresh.requestSizeLimit,
            finished: keepsParts ? plan.finishedBytes : [:]
        )
        saveManifest(next)
        if !keepsParts {
            try? FileManager.default.removeItem(at: plan.partsFolder)
            do {
                try FileManager.default.createDirectory(at: plan.partsFolder, withIntermediateDirectories: true)
            } catch {
                throw DownloadError.destinationNotWritable
            }
        }
        adopt(next)
        let reading = next.reading
        await changeSnapshot {
            $0.renewedMedia = fresh
            $0.fileName = fileName
            $0.apply(reading)
        }
        return next
    }

    private static func sameLayout(_ old: MediaSource, _ new: MediaSource) -> Bool {
        func layout(_ media: MediaSource) -> [[ClosedRange<Int64>?]] {
            media.tracks.map { track in ((track.initialization.map { [$0] } ?? []) + track.fragments).map(\.bytes) }
        }
        let before = layout(old)
        return before == layout(new) && !before.joined().contains(nil)
    }

    private func receive(_ piece: MediaPlan.Piece, of plan: MediaPlan) async throws {
        let position = piece.position
        let bytes = piece.fragment.bytes
        plan.start(position)
        defer { plan.stop(position) }
        let range = bytes.map { RangeRequest.closed(ByteRange(start: $0.lowerBound, end: $0.upperBound)) }
        let connection = connections.open(piece.fragment.url, range: range)
        defer { connection.cancel() }
        let response = try await connection.firstResponse()
        var skip: Int64 = 0
        var expected = response.knownLength
        switch response.statusCode {
        case 200:
            if let bytes {
                skip = bytes.lowerBound
                expected = Int64(bytes.count)
            }
        case 206 where bytes != nil:
            guard let bytes, ContentRange(response)?.range == ByteRange(start: bytes.lowerBound, end: bytes.upperBound) else {
                throw RetryableFailure()
            }
        default:
            throw connections.failure(for: response)
        }

        let part = plan.partURL(position)
        let temporary = part.appendingPathExtension("part")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temporary) else { throw DownloadError.destinationNotWritable }
        defer { try? handle.close() }
        var written: Int64 = 0
        let began = ContinuousClock.now
        for try await event in connection.events {
            guard case .data(let data) = event else { continue }
            if Self.isCrawling(written: written, since: began) { throw RetryableFailure() }
            var chunk = data
            if skip > 0 {
                let dropped = min(Int64(chunk.count), skip)
                chunk = Data(chunk.dropFirst(Int(dropped)))
                skip -= dropped
            }
            if let expected, written + Int64(chunk.count) > expected {
                chunk = Data(chunk.prefix(Int(expected - written)))
            }
            if !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                plan.add(Int64(chunk.count), to: position)
            }
            if let expected, written >= expected { break }
        }
        try RetryableFailure.throwIfEndedEarly(received: written, expected: expected)
        try handle.synchronize()
        if let key = piece.fragment.key { written = try await decrypt(temporary, with: key, of: plan) }
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: temporary, to: part)
        plan.finish(position, bytes: written)
    }

    static let crawlGrace = Duration.seconds(15)
    static let crawlBytesPerSecond: Int64 = 20_000

    static func isCrawling(written: Int64, since began: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Bool {
        let elapsed = now - began
        guard elapsed > crawlGrace else { return false }
        return written < crawlBytesPerSecond * Int64(elapsed.components.seconds)
    }

    private func reportingProgress(of plan: MediaPlan, _ work: () async throws -> Void) async throws {
        let reporter = Task {
            var meter = SpeedMeter()
            _ = meter.record(plan.reading.receivedBytes, at: .now)
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                ticks += 1
                if ticks.isMultiple(of: Self.ticksPerManifestSave) { saveManifest(plan) }
                let reading = plan.reading
                let speed = meter.record(reading.receivedBytes, at: .now)
                let remaining: TimeInterval? = reading.estimatedTotal.flatMap { total in
                    speed > 0 ? TimeInterval(max(total - reading.receivedBytes, 0)) / TimeInterval(speed) : nil
                }
                await changeSnapshot {
                    $0.apply(reading)
                    $0.bytesPerSecond = speed
                    $0.timeRemaining = remaining
                }
            }
        }
        do {
            try await work()
        } catch {
            reporter.cancel()
            await reporter.value
            throw error
        }
        reporter.cancel()
        await reporter.value
    }

    private func finish(_ plan: MediaPlan) async throws {
        let reading = plan.reading
        await changeSnapshot {
            $0.apply(reading)
            $0.bytesPerSecond = 0
            $0.timeRemaining = nil
            $0.state = .finalizing
        }
        saveManifest(plan)
        try Task.checkCancellation()
        guard let remux = configuration.remux else { throw DownloadError.mediaUnplayable }
        let joined = try join(plan)
        let output = plan.partial.packageURL.appending(path: "output.\(plan.media.fileExtension)")
        let extras = await fetchExtras(of: plan)
        try Task.checkCancellation()
        let request = RemuxRequest(
            tracks: joined, output: output, mediaSource: plan.media, subtitles: extras.subtitles,
            chapters: plan.media.extras?.chapters ?? [], coverArt: extras.coverArt
        )
        do {
            try await remux(request)
        } catch where request.hasExtras && !Task.isCancelled {
            do {
                try await remux(RemuxRequest(tracks: joined, output: output, mediaSource: plan.media.with(extras: nil)))
            } catch {
                throw DownloadError.mediaUnplayable
            }
        } catch {
            throw DownloadError.mediaUnplayable
        }
        try Task.checkCancellation()
        let finished = try plan.partial.finish(
            named: plan.fileName, in: plan.partial.packageURL.deletingLastPathComponent(),
            policy: options.nameConflictPolicy, source: url, replacingDataWith: output
        )
        partialFile.url = nil
        mediaPlans.forget()
        await changeSnapshot {
            $0.fileName = finished.name
            $0.wasSkipped = finished.wasSkipped
            $0.state = .completed
        }
    }

    static let largestExtra = 16 * 1024 * 1024

    private func fetchExtras(of plan: MediaPlan) async -> (subtitles: [RemuxRequest.SubtitleFile], coverArt: URL?) {
        guard let extras = plan.media.extras else { return ([], nil) }
        var subtitles: [RemuxRequest.SubtitleFile] = []
        for (index, subtitle) in extras.subtitles.enumerated() {
            let file = plan.partial.packageURL.appending(path: "subtitle-\(index).\(subtitle.format)")
            if await fetchWhole(subtitle.url, to: file) {
                subtitles.append(RemuxRequest.SubtitleFile(file: file, language: subtitle.language, name: subtitle.name))
            }
        }
        var cover: URL?
        if let art = extras.coverArt {
            let file = plan.partial.packageURL.appending(path: "cover.\(art.pathExtension.isEmpty ? "jpg" : art.pathExtension.lowercased())")
            if await fetchWhole(art, to: file) { cover = file }
        }
        return (subtitles, cover)
    }

    private func fetchWhole(_ url: URL, to file: URL) async -> Bool {
        let connection = connections.open(url, range: nil)
        defer { connection.cancel() }
        guard let response = try? await connection.firstResponse(), response.statusCode == 200 else { return false }
        var data = Data()
        do {
            for try await event in connection.events {
                guard case .data(let chunk) = event else { continue }
                data.append(chunk)
                if data.count > Self.largestExtra { return false }
            }
        } catch {
            return false
        }
        return !data.isEmpty && FileManager.default.createFile(atPath: file.path, contents: data)
    }

    private func join(_ plan: MediaPlan) throws -> [URL] {
        try plan.media.tracks.indices.map { track in
            let parts = plan.pieces.filter { $0.position.track == track }.map { plan.partURL($0.position) }
            let head = (try? FileHandle(forReadingFrom: parts[0])).flatMap { try? $0.read(upToCount: 4) } ?? Data()
            let joined = plan.partial.packageURL.appending(path: "track-\(track).\(Self.fileExtension(of: head, kind: plan.media.tracks[track].kind))")
            guard FileManager.default.createFile(atPath: joined.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: joined) else { throw DownloadError.destinationNotWritable }
            defer { try? output.close() }
            var timeline = TransportStreamTimeline()
            let isTransportStream = head.first == 0x47
            for part in parts {
                if isTransportStream {
                    try output.write(contentsOf: timeline.continued(try Data(contentsOf: part)))
                    continue
                }
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
            return joined
        }
    }

    static func fileExtension(of head: Data, kind: MediaTrack.Kind) -> String {
        let bytes = [UInt8](head)
        if bytes.first == 0x47 { return "ts" }
        if bytes.starts(with: Array("ID3".utf8)) || (bytes.count > 1 && bytes[0] == 0xFF && bytes[1] & 0xF0 == 0xF0) { return "aac" }
        return kind == .audio ? "m4a" : "mp4"
    }

    func saveManifest(_ plan: MediaPlan) {
        let manifest = PartialFileManifest(
            formatVersion: PartialFileManifest.currentFormatVersion,
            downloadID: id.description,
            originalURL: url,
            finalURL: url,
            validator: nil,
            totalBytes: nil,
            fileName: plan.fileName,
            connections: options.connections,
            referrer: options.referrer,
            userAgent: options.userAgent,
            origin: options.origin,
            segments: [],
            layout: nil,
            nameConflictPolicy: options.nameConflictPolicy,
            mediaSource: plan.media,
            finishedFragments: plan.finishedPositions,
            requestSizeLimit: options.requestSizeLimit ?? plan.media.requestSizeLimit
        )
        try? plan.partial.saveManifest(manifest)
    }

    private func fail(with error: DownloadError, _ plan: MediaPlan?) async {
        if let plan { saveManifest(plan) }
        let reading = plan?.reading
        await changeSnapshot {
            if let reading { $0.apply(reading) }
            $0.bytesPerSecond = 0
            $0.timeRemaining = nil
            $0.state = .failed(error)
        }
    }
}

extension DownloadSnapshot {
    mutating func apply(_ reading: MediaPlan.Reading) {
        receivedBytes = reading.receivedBytes
        totalBytes = reading.estimatedTotal
        activeConnections = reading.activeConnections
        let whole = reading.estimatedTotal.map { [SegmentProgress(start: 0, end: max($0 - 1, 0), receivedBytes: min(reading.receivedBytes, $0))] } ?? []
        segments = whole
        plannedSegments = whole.map { SegmentBounds(start: $0.start, end: $0.end) }
    }
}

final class LatestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: YTDLPProgress?

    func set(_ progress: YTDLPProgress) {
        lock.withLock { value = progress }
    }

    func take() -> YTDLPProgress? {
        lock.withLock {
            defer { value = nil }
            return value
        }
    }
}
