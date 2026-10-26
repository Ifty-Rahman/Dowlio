import DowlioCore
import DowlioMedia
import Foundation

public struct SentPageDraft: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case looking
        case found
        case nothingFound
    }

    public enum Showing: Equatable, Sendable {
        case video
        case audio
    }

    public struct Download: Equatable, Sendable {
        public var candidate: Candidate
        public var version: Version
    }

    public let page: SentPage
    public private(set) var phase = Phase.looking
    public private(set) var candidates: [Candidate] = []
    public private(set) var selected = 0
    private var excluded: Set<Int> = []
    private var picks: [Int: Version] = [:]

    public init(page: SentPage) {
        self.page = page
    }

    public var host: String {
        let host = page.url.host(percentEncoded: false)?.lowercased() ?? page.url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public var sourceLine: String {
        guard let browser = page.browser else { return host }
        return "\(host) · from \(browser)" + (page.cookies.isEmpty ? "" : ", signed in")
    }

    public mutating func update(_ analysis: PageAnalysis) -> URL? {
        switch analysis {
        case .looking:
            return nil
        case .plainFile(let url):
            return url
        case .found(let found):
            candidates = found
            selected = 0
            excluded = []
            picks = [:]
            phase = found.isEmpty ? .nothingFound : .found
            return nil
        }
    }

    public var selectedCandidate: Candidate? {
        candidates.indices.contains(selected) ? candidates[selected] : nil
    }

    public mutating func select(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        selected = index
    }

    public func chosenVersion(of index: Int) -> Version? {
        guard candidates.indices.contains(index) else { return nil }
        if let pick = picks[index], candidates[index].versions.contains(pick) { return pick }
        return candidates[index].versions.first
    }

    public var chosenVersion: Version? { chosenVersion(of: selected) }

    public mutating func pick(_ version: Version) {
        picks[selected] = version
    }

    public func isIncluded(_ index: Int) -> Bool { !excluded.contains(index) }

    public mutating func include(_ index: Int, _ included: Bool) {
        if included { excluded.remove(index) } else { excluded.insert(index) }
    }

    public var downloads: [Download] {
        candidates.indices.compactMap { index in
            guard isIncluded(index), let version = chosenVersion(of: index) else { return nil }
            return Download(candidate: candidates[index], version: version)
        }
    }

    public var hasVideoAndAudio: Bool {
        let versions = selectedCandidate?.versions ?? []
        return versions.contains(where: MediaText.isAudio) && versions.contains { !MediaText.isAudio($0) }
    }

    public func versions(showing: Showing) -> [Version] {
        (selectedCandidate?.versions ?? []).filter { MediaText.isAudio($0) == (showing == .audio) }
    }

    public static func fileName(for candidate: Candidate, version: Version) -> String {
        let ext = version.source.url.pathExtension
        let cleaned = candidate.label
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? version.source.url.deletingPathExtension().lastPathComponent : String(cleaned.prefix(120))
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}

public enum MediaText {
    public static func isAudio(_ version: Version) -> Bool {
        MediaFile.kind(of: version.source.url, contentType: version.contentType) == .audio
    }

    public static func title(of version: Version) -> String {
        let ext = version.source.url.pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return version.contentType?.split(separator: "/").last.map { $0.uppercased() } ?? "File"
    }

    public static func size(of version: Version) -> String? {
        version.totalBytes.map(ByteText.string)
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
