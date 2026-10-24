import DowlioCore
import Foundation

struct DownloadRun: Sendable {
    typealias ChangeSnapshot = @Sendable (@escaping @Sendable (inout DownloadSnapshot) -> Void) async -> Void

    let id: DownloadID
    let url: URL
    let destination: Destination
    let options: RequestOptions
    let partialFile: PartialFileLocation
    let configuration: EngineConfiguration
    let changeSnapshot: ChangeSnapshot
    let connections: ConnectionOpener
    let probe: ServerProbe
    let planStore = PlanStore()
    let retries = RetryTracker()
    let gate = ConnectionGate()

    init(
        id: DownloadID,
        url: URL,
        destination: Destination,
        options: RequestOptions,
        partialFile: PartialFileLocation,
        configuration: EngineConfiguration,
        changeSnapshot: @escaping ChangeSnapshot
    ) {
        self.id = id
        self.url = url
        self.destination = destination
        self.options = options
        self.partialFile = partialFile
        self.configuration = configuration
        self.changeSnapshot = changeSnapshot
        connections = ConnectionOpener(
            originalURL: url, options: options, idleTimeout: configuration.idleTimeout,
            sessions: configuration.sessions, now: configuration.now
        )
        probe = ServerProbe(connections: connections)
    }

    func run(resuming: Bool = false) async {
        var current: DownloadPlan?
        do {
            var plan = try await prepare(resuming: resuming)
            current = plan
            saveManifest(plan)
            // A second change in a row fails the download, so bytes from two versions are never mixed.
            var startedOverForChange = false
            while true {
                let attempt = plan
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
                    let probed = try await probeWithRetries(url)
                    plan = try await startOver(attempt, with: probed)
                    current = plan
                    saveManifest(plan)
                } catch is RangesUnusable {
                    let whole = try await withRetries(.whole, host: attempt.finalURL) {
                        try await probe.openWholeFile(at: attempt.finalURL)
                    }
                    plan = try await startOver(attempt, with: whole)
                    current = plan
                    saveManifest(plan)
                }
            }
            try await finish(plan)
        } catch where Task.isCancelled {
            if let current {
                saveManifest(current)
                let reading = current.board.reading
                await changeSnapshot { $0.apply(reading) }
            }
        } catch let error as DownloadError {
            await fail(with: error, current)
        } catch {
            await fail(with: .network(NetworkFailure(error)), current)
        }
    }

    /// The connection setting, clamped to 1 to 16.
    var connectionSetting: Int {
        min(max(options.connections, 1), SegmentPlanner.maximumConnections)
    }

    func adopt(_ plan: DownloadPlan) {
        partialFile.url = plan.partial.packageURL
        planStore.store(plan, probeConnection: nil)
    }

    /// Lets go of everything the download holds, for a download that's cancelled.
    func discard() {
        planStore.forget()
    }

    private func prepare(resuming: Bool) async throws -> DownloadPlan {
        if let plan = planStore.plan, plan.partial.isMissing {
            planStore.forget()
            partialFile.url = nil
        }
        if let plan = planStore.plan {
            if resuming { return try await revalidate(plan) }
            await changeSnapshot { $0.state = .downloading }
            return plan
        }

        let probed = try await probeWithRetries(url)
        let fileName = options.fileName.map(FileNaming.chosen)
            ?? FileNaming.name(for: probed.probeResponse, finalURL: probed.finalURL)
        let folder = destination.folder(forFileNamed: fileName, contentType: probed.probeResponse.contentTypeHeader)
        await changeSnapshot {
            $0.state = .downloading
            $0.fileName = fileName
            $0.destinationFolder = folder
            $0.totalBytes = probed.totalBytes
            $0.isNotSecure = probed.finalURL.isPlainHTTP || url.isPlainHTTP
        }

        let plan: DownloadPlan
        do {
            if folder != destination.root {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                } catch {
                    throw DownloadError.destinationNotWritable
                }
            }
            let partial = try PartialFile.create(for: fileName, in: folder)
            partialFile.url = partial.packageURL
            plan = try layOut(probed, fileName: fileName, in: partial)
        } catch {
            probed.cancelConnection()
            throw error
        }
        await changeSnapshot { $0.canResume = plan.canResume }
        return plan
    }

    private func revalidate(_ plan: DownloadPlan) async throws -> DownloadPlan {
        let probed = try await probeForResume(plan)
        if case .ranges(let total, let validator?) = probed.body,
           case .ranges(let saved?) = plan.layout,
           total == plan.totalBytes, validator == saved {
            var kept = plan
            kept.finalURL = probed.finalURL
            applyHostLimit(of: kept.finalURL)
            planStore.store(kept, probeConnection: nil)
            await changeSnapshot { $0.state = .downloading }
            return kept
        }

        return try await startOver(plan, with: probed)
    }

    private func startOver(_ plan: DownloadPlan, with probed: Probed) async throws -> DownloadPlan {
        let restarted: DownloadPlan
        do {
            try plan.partial.discardData()
            restarted = try layOut(probed, fileName: plan.fileName, in: plan.partial)
        } catch {
            probed.cancelConnection()
            throw error
        }
        let reading = restarted.board.reading
        await changeSnapshot {
            $0.state = .downloading
            $0.totalBytes = restarted.totalBytes
            $0.canResume = restarted.canResume
            $0.apply(reading)
        }
        return restarted
    }

    private func fail(with error: DownloadError, _ plan: DownloadPlan?) async {
        if let plan { saveManifest(plan) }
        let reading = plan?.board.reading
        await changeSnapshot {
            if let reading { $0.apply(reading) }
            $0.bytesPerSecond = 0
            $0.timeRemaining = nil
            $0.state = .failed(error)
        }
    }
}
