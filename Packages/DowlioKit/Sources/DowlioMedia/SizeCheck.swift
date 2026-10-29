import DowlioCore
import Foundation

struct SizeCheck: Sendable {
    typealias Options = @Sendable (URL, Version) -> RequestOptions
    typealias FragmentOptions = @Sendable (URL) -> RequestOptions

    static let candidatesChecked = PageLayout.probedAtOnce
    static let sampledFragments = 3

    let inspect: PageAnalyzer.Inspect
    let slots = HostSlots(perHost: 4)

    func sized(_ candidates: [Candidate], options: @escaping Options) async -> [Candidate] {
        await withTaskGroup(of: (Int, Int, Version).self) { group in
            for (row, candidate) in candidates.enumerated().prefix(Self.candidatesChecked) {
                for (index, version) in candidate.versions.enumerated() where needsCheck(version) {
                    group.addTask { (row, index, await self.checked(version, options: options)) }
                }
            }
            var sized = candidates
            for await (row, index, version) in group { sized[row].versions[index] = version }
            return sized
        }
    }

    private func needsCheck(_ version: Version) -> Bool {
        !version.isExtractedAudio && (version.totalBytes == nil || version.isEstimatedSize)
    }

    private struct Size {
        var bytes: Int64
        var isExact: Bool
    }

    private func checked(_ version: Version, options: @escaping Options) async -> Version {
        let found: Size?
        switch version.source {
        case .file(let url):
            found = await exactSize(of: url, options: options(url, version))
        case .media(let media):
            found = await size(ofTracks: media.tracks) { options($0, version) }
        }
        guard let found else { return version }
        var sized = version
        sized.totalBytes = found.bytes
        sized.isEstimatedSize = !found.isExact
        return sized
    }

    private func size(ofTracks tracks: [MediaTrack], options: @escaping FragmentOptions) async -> Size? {
        var total = Size(bytes: 0, isExact: true)
        for track in tracks {
            guard let size = await size(ofTrack: track, options: options) else { return nil }
            total.bytes += size.bytes
            total.isExact = total.isExact && size.isExact
        }
        return total
    }

    private func size(ofTrack track: MediaTrack, options: @escaping FragmentOptions) async -> Size? {
        let all = (track.initialization.map { [$0] } ?? []) + track.fragments
        if all.count == 1, all[0].bytes == nil { return await exactSize(of: all[0].url, options: options(all[0].url)) }
        let ranges = all.compactMap(\.bytes)
        guard ranges.count == all.count else { return await estimate(track, options: options) }
        if Set(all.map(\.url)).count == 1, let end = ranges.map(\.upperBound).max() { return Size(bytes: end + 1, isExact: true) }
        return Size(bytes: ranges.reduce(0) { $0 + $1.byteCount }, isExact: true)
    }

    private func estimate(_ track: MediaTrack, options: @escaping FragmentOptions) async -> Size? {
        let fragments = track.fragments
        guard !fragments.isEmpty, fragments.allSatisfy({ $0.bytes == nil }) else { return nil }
        let picked = Self.spread(count: fragments.count, picking: Self.sampledFragments).map { fragments[$0].url }
        let sizes = await withTaskGroup(of: Int64?.self) { group in
            for url in picked { group.addTask { await self.askedSize(of: url, options: options(url)) } }
            var found: [Int64] = []
            for await size in group { if let size { found.append(size) } }
            return found
        }
        guard sizes.count == picked.count else { return nil }
        var headerBytes: Int64 = 0
        if let header = track.initialization {
            if let range = header.bytes {
                headerBytes = range.byteCount
            } else if let asked = await askedSize(of: header.url, options: options(header.url)) {
                headerBytes = asked
            } else {
                return nil
            }
        }
        let average = sizes.reduce(0, +) / Int64(sizes.count)
        return Size(bytes: average * Int64(fragments.count) + headerBytes, isExact: false)
    }

    static func spread(count: Int, picking wanted: Int) -> [Int] {
        guard count > wanted else { return Array(0..<count) }
        return (0..<wanted).map { (2 * $0 + 1) * count / (2 * wanted) }
    }

    private func exactSize(of url: URL, options: RequestOptions) async -> Size? {
        await askedSize(of: url, options: options).map { Size(bytes: $0, isExact: true) }
    }

    private func askedSize(of url: URL, options: RequestOptions) async -> Int64? {
        let host = url.host(percentEncoded: false) ?? ""
        await slots.take(host)
        let size = try? await inspect(url, options).totalBytes
        await slots.give(host)
        return size
    }
}

actor HostSlots {
    private let perHost: Int
    private var busy: [String: Int] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(perHost: Int) {
        self.perHost = perHost
    }

    func take(_ host: String) async {
        if busy[host, default: 0] < perHost {
            busy[host, default: 0] += 1
            return
        }
        await withCheckedContinuation { waiting[host, default: []].append($0) }
    }

    func give(_ host: String) {
        guard var queue = waiting[host], !queue.isEmpty else {
            busy[host] = max((busy[host] ?? 0) - 1, 0)
            return
        }
        queue.removeFirst().resume()
        waiting[host] = queue.isEmpty ? nil : queue
    }
}

private extension ClosedRange where Bound == Int64 {
    var byteCount: Int64 { upperBound - lowerBound + 1 }
}
