import DowlioCore
import Foundation

public struct PageAnalyzer: Sendable {
    public typealias Inspect = @Sendable (URL, RequestOptions) async throws -> LinkInspection

    static let largestPage = 8 * 1024 * 1024

    private let inspect: Inspect
    private let session: URLSession

    public init(session: URLSession = .shared, inspect: @escaping Inspect) {
        self.session = session
        self.inspect = inspect
    }

    public func analyze(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        AsyncStream { continuation in
            let task = Task {
                await run(page) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ page: SentPage, report: (PageAnalysis) -> Void) async {
        if let linked = try? await inspect(page.url, pageOptions(page)), !linked.isWebPage {
            let version = Version(source: .file(page.url), contentType: linked.contentType, totalBytes: linked.totalBytes)
            guard Self.kind(of: linked) != nil else { return report(.plainFile(page.url)) }
            return report(.found([Candidate(label: linked.fileName, versions: [version])]))
        }

        let reading = await read(page)
        var players = Players()
        for media in page.scan { players.add(media, from: "page") }
        for media in reading?.media ?? [] { players.add(media, from: "html") }
        let shown = Set(players.list.flatMap(\.sources).map(\.url))
        for request in page.watched where request.kind == .file {
            players.add(ScannedMedia(url: request.url, kind: MediaFile.kind(of: request.url, contentType: request.contentType) ?? .video), from: "watched")
        }
        let label = reading?.title ?? page.title ?? page.url.host() ?? page.url.absoluteString
        let candidates = players.list.map { player in
            Candidate(label: label, thumbnail: player.poster ?? reading?.image, duration: player.duration ?? reading?.duration, versions: [])
        }
        if !candidates.isEmpty { report(.looking(candidates)) }

        let options = mediaOptions(page)
        let sources = players.list.flatMap(\.sources)
        let versions = await withTaskGroup(of: (URL, Version?).self) { group in
            for media in sources {
                group.addTask { [inspect] in
                    let url = media.url
                    guard let inspection = try? await inspect(url, options), Self.kind(of: inspection) != nil else { return (url, nil) }
                    return (url, Version(
                        source: .file(url), contentType: inspection.contentType, totalBytes: inspection.totalBytes,
                        height: media.height ?? MediaFile.height(in: url.path), codecs: media.codecs ?? MediaFile.codecs(in: url.path)
                    ))
                }
            }
            var found: [URL: Version] = [:]
            for await (url, version) in group { found[url] = version }
            return found
        }
        let kept = players.list.enumerated().compactMap { index, player -> Candidate? in
            var candidate = candidates[index]
            candidate.versions = player.sources.compactMap { versions[$0.url] }.filter { version in
                shown.contains(version.source.url) || !Self.looksLikeAnAd(version, on: page.url)
            }
            return candidate.versions.isEmpty ? nil : candidate
        }
        report(.found(kept))
    }

    private struct Players {
        struct Player {
            var key: String
            var sources: [ScannedMedia]
            var poster: URL? { sources.lazy.compactMap(\.poster).first }
            var duration: Double? { sources.lazy.compactMap(\.duration).first }
        }

        private(set) var list: [Player] = []

        mutating func add(_ media: ScannedMedia, from origin: String) {
            guard !list.contains(where: { $0.sources.contains { $0.url == media.url } }) else { return }
            let key: String
            if media.group == HTMLReader.downloadLinks || (origin != "watched" && media.group == nil && MediaFile.height(in: media.url.path) != nil) {
                key = "download-links"
            } else {
                key = media.group.map { "\(origin)-\($0)" } ?? media.url.absoluteString
            }
            if let index = list.firstIndex(where: { $0.key == key }) {
                list[index].sources.append(media)
            } else {
                list.append(Player(key: key, sources: [media]))
            }
        }
    }

    private static let smallestWatchedFileFromAnotherSite: Int64 = 1_000_000

    private static func looksLikeAnAd(_ version: Version, on page: URL) -> Bool {
        guard let size = version.totalBytes, size < smallestWatchedFileFromAnotherSite else { return false }
        return site(of: version.source.url) != site(of: page)
    }

    private static func site(of url: URL) -> String {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        let labels = host.split(separator: ".")
        if labels.isEmpty || host.contains(":") || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host + port }
        let countryCoded = labels.count > 2 && labels.last?.count == 2 && (labels.dropLast().last?.count ?? 0) <= 3
        return labels.suffix(countryCoded ? 3 : 2).joined(separator: ".") + port
    }

    private static func kind(of inspection: LinkInspection) -> ScannedMedia.Kind? {
        guard !inspection.isWebPage else { return nil }
        switch inspection.category {
        case .video: return .video
        case .audio: return .audio
        default: return nil
        }
    }

    private func read(_ page: SentPage) async -> HTMLReader? {
        var request = URLRequest(url: page.url)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let agent = page.userAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        if !page.cookies.isEmpty {
            request.setValue(page.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              LinkInspection.isWebPage(mimeType: http.value(forHTTPHeaderField: "Content-Type")),
              data.count <= Self.largestPage
        else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        return HTMLReader(html, base: http.url ?? page.url)
    }

    private func pageOptions(_ page: SentPage) -> RequestOptions {
        var options = RequestOptions()
        options.cookies = page.cookies
        options.userAgent = page.userAgent
        return options
    }

    private func mediaOptions(_ page: SentPage) -> RequestOptions {
        var options = pageOptions(page)
        options.referrer = page.url
        return options
    }
}
