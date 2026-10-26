import Foundation

struct DownloadPlan: Sendable {
    enum Layout: Sendable {
        case whole
        case ranges(validator: String?)
    }

    let fileName: String
    var finalURL: URL
    let totalBytes: Int64?
    let layout: Layout
    let segments: [ByteRange]
    let partial: PartialFile
    let board: ProgressBoard

    /// Without a strong validator a resume can't tell that the file changed, so it starts over.
    var canResume: Bool {
        if case .ranges(_?) = layout, totalBytes != nil { true } else { false }
    }
}

/// Outlives one run, so Retry and Resume continue from the same plan.
final class PlanStore: @unchecked Sendable {
    // @unchecked: both stored properties are only read or written under `lock`.
    private let lock = NSLock()
    private var stored: DownloadPlan?
    private var held: HeldConnection?

    var plan: DownloadPlan? { lock.withLock { stored } }

    func store(_ plan: DownloadPlan, holding connection: HeldConnection?) {
        let dropped: Connection? = lock.withLock {
            defer {
                stored = plan
                held = connection
            }
            return held?.connection === connection?.connection ? nil : held?.connection
        }
        dropped?.cancel()
    }

    func takeConnection(startingAt start: Int64) -> Connection? {
        lock.withLock {
            guard let held, held.start == start else { return nil }
            self.held = nil
            return held.connection
        }
    }

    func closeHeldConnection() {
        let dropped: Connection? = lock.withLock {
            defer { held = nil }
            return held?.connection
        }
        dropped?.cancel()
    }

    func forget() {
        lock.withLock { stored = nil }
        closeHeldConnection()
    }
}

struct HeldConnection {
    let connection: Connection
    let start: Int64
}
