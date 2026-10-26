import DowlioCore
import DowlioMedia
import Foundation

public struct SentPageDraft: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case looking
        case oneVideo(Candidate)
        case several([Candidate])
        case nothingFound
        case started(DownloadID)
    }

    public struct Download: Equatable, Sendable {
        public var source: DownloadSource
        public var options: RequestOptions
        public var origin: DownloadOrigin
    }

    public let page: SentPage
    public private(set) var phase = Phase.looking
    private var found: [Candidate] = []
    private var picked: Version?

    public init(page: SentPage) {
        self.page = page
    }

    public var host: String {
        let host = page.url.host(percentEncoded: false)?.lowercased() ?? page.url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public mutating func update(_ analysis: PageAnalysis) -> URL? {
        switch analysis {
        case .looking:
            return nil
        case .plainFile(let url):
            return url
        case .found(let candidates):
            found = candidates
            phase = switch candidates.count {
            case 0: .nothingFound
            case 1: .oneVideo(candidates[0])
            default: .several(candidates)
            }
            return nil
        }
    }

    public mutating func choose(_ candidate: Candidate) {
        phase = .oneVideo(candidate)
        picked = nil
    }

    public var chosenVersion: Version? {
        guard case .oneVideo(let candidate) = phase else { return nil }
        if let picked, candidate.versions.contains(picked) { return picked }
        return candidate.versions.first
    }

    public mutating func pick(_ version: Version) {
        picked = version
    }

    public mutating func backToList() {
        guard found.count > 1 else { return }
        phase = .several(found)
    }

    public var canGoBack: Bool {
        if case .oneVideo = phase { found.count > 1 } else { false }
    }

    public mutating func started(_ id: DownloadID) {
        phase = .started(id)
    }

    public func download(_ version: Version) -> Download {
        var options = RequestOptions()
        options.cookies = page.cookies
        options.userAgent = page.userAgent
        options.referrer = page.url
        return Download(source: version.source, options: options, origin: DownloadOrigin(kind: .sent, browser: page.browser))
    }

    public static func summary(of version: Version) -> String {
        let ext = version.source.url.pathExtension.uppercased()
        let subtype = version.contentType?.split(separator: "/").last.map { $0.uppercased() }
        var parts = [ext.isEmpty ? subtype : ext].compactMap { $0 }
        if let size = version.totalBytes { parts.append(ByteText.string(size)) }
        return parts.joined(separator: " · ")
    }

    public static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
