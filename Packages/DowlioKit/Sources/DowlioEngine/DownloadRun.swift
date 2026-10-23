import DowlioCore
import Foundation

/// Runs one download: probes the server, receives the bytes into the partial file, then puts the
/// finished file in place. Running it again after it failed continues from the bytes it has.
struct DownloadRun: Sendable {
    typealias ChangeSnapshot = @Sendable (@escaping @Sendable (inout DownloadSnapshot) -> Void) async -> Void

    let id: DownloadID
    let url: URL
    let folder: URL
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
        connections = ConnectionOpener(
            originalURL: url, options: options, idleTimeout: configuration.idleTimeout, now: configuration.now
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

    func adopt(_ plan: DownloadPlan) {
        partialFile.url = plan.partial.packageURL
        planStore.store(plan, probeConnection: nil)
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
        let fileName = FileNaming.name(for: probed.probeResponse, finalURL: probed.finalURL)
        await changeSnapshot {
            $0.state = .downloading
            $0.fileName = fileName
            $0.totalBytes = probed.totalBytes
            $0.isNotSecure = probed.finalURL.isPlainHTTP || url.isPlainHTTP
        }

        let partial = try PartialFile.create(for: fileName, in: folder)
        partialFile.url = partial.packageURL
        let plan = try layOut(probed, fileName: fileName, in: partial)
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
            planStore.store(kept, probeConnection: nil)
            await changeSnapshot { $0.state = .downloading }
            return kept
        }

        return try await startOver(plan, with: probed)
    }

    private func startOver(_ plan: DownloadPlan, with probed: Probed) async throws -> DownloadPlan {
        try plan.partial.discardData()
        let restarted = try layOut(probed, fileName: plan.fileName, in: plan.partial)
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
