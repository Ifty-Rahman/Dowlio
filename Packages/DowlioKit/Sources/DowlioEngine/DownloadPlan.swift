import Foundation

/// What a download learned from its probe, how its segments are laid out, and where its bytes go.
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

/// The plan, kept between runs for Retry and Resume, and the probe's connection, which only the
/// first try may read.
final class PlanStore: @unchecked Sendable {
    // @unchecked: both stored properties are only read or written under `lock`.
    private let lock = NSLock()
    private var stored: DownloadPlan?
    private var probeConnection: Connection?

    var plan: DownloadPlan? { lock.withLock { stored } }

    func store(_ plan: DownloadPlan, probeConnection: Connection?) {
        lock.withLock {
            stored = plan
            self.probeConnection = probeConnection
        }
    }

    func takeProbeConnection() -> Connection? {
        lock.withLock {
            defer { probeConnection = nil }
            return probeConnection
        }
    }

    func forget() {
        lock.withLock {
            stored = nil
            probeConnection = nil
        }
    }
}
