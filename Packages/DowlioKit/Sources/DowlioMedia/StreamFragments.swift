import DowlioCore
import Foundation

final class StreamFragments: @unchecked Sendable {
    private let lock = NSLock()
    private var listed = Set<String>()

    func note(_ playlist: MediaPlaylist) {
        guard playlist.singleFile == nil else { return }
        let found = playlist.allFragments.map { PageAnalyzer.withoutQuery($0.url) }
        lock.withLock { listed.formUnion(found) }
    }

    func withoutListedFragments(in candidates: [Candidate]) -> [Candidate] {
        let listed: Set<String> = lock.withLock { self.listed }
        guard !listed.isEmpty else { return candidates }
        return candidates.compactMap { candidate in
            var kept = candidate
            kept.versions = candidate.versions.filter { version in
                guard case .file(let url) = version.source else { return true }
                return !listed.contains(PageAnalyzer.withoutQuery(url))
            }
            return kept.versions.isEmpty && !candidate.versions.isEmpty ? nil : kept
        }
    }

    private static let alwaysFragmentExtensions: Set<String> = ["m4s", "m4f", "cmfv", "cmfa"]
    private static let fragmentExtensions: Set<String> = alwaysFragmentExtensions.union(["ts"])
    private static let fragmentPrefixes = ["init", "seg-", "segment", "frag", "chunk"]
    private static let initExtensions: Set<String> = ["mp4", "m4v", "m4a", "m4s", "cmfv", "cmfa"]

    static func isNamedLikeAFragment(_ url: URL, nextTo streams: [URL]) -> Bool {
        if alwaysFragmentExtensions.contains(url.pathExtension.lowercased()) { return true }
        let folder = url.deletingLastPathComponent().path
        guard streams.contains(where: { $0.host() == url.host() && $0.deletingLastPathComponent().path == folder }) else { return false }
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if fragmentExtensions.contains(ext) { return true }
        return fragmentPrefixes.contains { name.hasPrefix($0) } && initExtensions.contains(ext)
    }
}

extension MediaPlaylist {
    var allFragments: [MediaFragment] {
        (initialization.map { [$0] } ?? []) + fragments
    }

    var fragmentNames: String {
        ([allFragments.first?.url.host() ?? ""] + allFragments.map(\.url.lastPathComponent)).joined(separator: "/")
    }
}
