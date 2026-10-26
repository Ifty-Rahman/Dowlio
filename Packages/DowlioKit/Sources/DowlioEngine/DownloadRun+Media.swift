import DowlioCore
import Foundation

extension DownloadRun {
    func runMedia(_ media: MediaSource, resuming: Bool) async {
        var current: MediaPlan?
        do {
            let plan = try await prepareMedia(media)
            current = plan
            saveManifest(plan)
            try await reportingProgress(of: plan) {
                try await receivePieces(of: plan, resuming: resuming)
            }
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
        let folder = destination.folder(forFileNamed: fileName, contentType: contentType)
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
        let plan = MediaPlan(fileName: fileName, media: media, partial: partial)
        adopt(plan)
        do {
            try FileManager.default.createDirectory(at: plan.partsFolder, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.destinationNotWritable
        }
        return plan
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
        for try await event in connection.events {
            guard case .data(let data) = event else { continue }
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
        do {
            try await remux(joined, output)
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

    private func join(_ plan: MediaPlan) throws -> [URL] {
        try plan.media.tracks.indices.map { track in
            let parts = plan.pieces.filter { $0.position.track == track }.map { plan.partURL($0.position) }
            let head = (try? FileHandle(forReadingFrom: parts[0])).flatMap { try? $0.read(upToCount: 4) } ?? Data()
            let joined = plan.partial.packageURL.appending(path: "track-\(track).\(Self.fileExtension(of: head, kind: plan.media.tracks[track].kind))")
            guard FileManager.default.createFile(atPath: joined.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: joined) else { throw DownloadError.destinationNotWritable }
            defer { try? output.close() }
            for part in parts {
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
            segments: [],
            layout: nil,
            nameConflictPolicy: options.nameConflictPolicy,
            mediaSource: plan.media,
            finishedFragments: plan.finishedPositions
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
