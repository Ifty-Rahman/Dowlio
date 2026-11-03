import DowlioCore
import Foundation

final class MediaPlan: @unchecked Sendable {
    struct Piece: Sendable {
        let position: FragmentPosition
        let fragment: MediaFragment
    }

    let fileName: String
    let media: MediaSource
    let partial: PartialFile
    let pieces: [Piece]
    let keys = FragmentKeys()
    private let lock = NSLock()
    private var finished: [FragmentPosition: Int64]
    private var receiving: [FragmentPosition: Int64] = [:]

    init(fileName: String, media: MediaSource, partial: PartialFile, finished: [FragmentPosition: Int64] = [:]) {
        self.fileName = fileName
        self.media = media
        self.partial = partial
        self.finished = finished
        pieces = media.tracks.enumerated().flatMap { track, content in
            ((content.initialization.map { [$0] } ?? []) + content.fragments).enumerated().map {
                Piece(position: FragmentPosition(track: track, fragment: $0.offset), fragment: $0.element)
            }
        }
    }

    convenience init(restoring media: MediaSource, fileName: String, partial: PartialFile, finished positions: [FragmentPosition]) {
        self.init(fileName: fileName, media: media, partial: partial)
        let sizes = positions.compactMap { position -> (FragmentPosition, Int64)? in
            let path = partURL(position).path
            guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 else { return nil }
            return (position, size)
        }
        lock.withLock { finished = Dictionary(sizes) { first, _ in first } }
    }

    var partsFolder: URL { partial.packageURL.appending(path: "parts", directoryHint: .isDirectory) }

    func partURL(_ position: FragmentPosition) -> URL {
        partsFolder.appending(path: "\(position.track)-\(position.fragment)")
    }

    var waiting: [Piece] {
        lock.withLock { pieces.filter { finished[$0.position] == nil } }
    }

    var finishedPositions: [FragmentPosition] {
        lock.withLock { finished.keys.sorted { ($0.track, $0.fragment) < ($1.track, $1.fragment) } }
    }

    func start(_ position: FragmentPosition) {
        lock.withLock { receiving[position] = 0 }
    }

    func add(_ count: Int64, to position: FragmentPosition) {
        lock.withLock { receiving[position, default: 0] += count }
    }

    func stop(_ position: FragmentPosition) {
        _ = lock.withLock { receiving.removeValue(forKey: position) }
    }

    func finish(_ position: FragmentPosition, bytes: Int64) {
        lock.withLock {
            receiving[position] = nil
            finished[position] = bytes
        }
    }

    struct Reading: Equatable {
        var receivedBytes: Int64
        var estimatedTotal: Int64?
        var activeConnections: Int
    }

    var reading: Reading {
        lock.withLock {
            let done = finished.values.reduce(0, +)
            let received = done + receiving.values.reduce(0, +)
            let total: Int64? = finished.isEmpty ? nil : finished.count == pieces.count
                ? done
                : max(received, done + done / Int64(finished.count) * Int64(pieces.count - finished.count))
            return Reading(receivedBytes: received, estimatedTotal: total, activeConnections: receiving.count)
        }
    }
}

final class MediaPlanStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MediaPlan?

    var plan: MediaPlan? { lock.withLock { stored } }

    func store(_ plan: MediaPlan) {
        lock.withLock { stored = plan }
    }

    func forget() {
        lock.withLock { stored = nil }
    }
}

final class PieceQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [MediaPlan.Piece]

    init(_ pieces: [MediaPlan.Piece]) {
        self.pieces = pieces.reversed()
    }

    func next() -> MediaPlan.Piece? {
        lock.withLock { pieces.popLast() }
    }
}
