import DowlioCore
import Foundation

public struct PageAnalyzer: Sendable {
    public typealias Inspect = @Sendable (URL, RequestOptions) async throws -> LinkInspection

    static let largestPage = 8 * 1024 * 1024

    private let inspect: Inspect
    private let session: URLSession
    private let play: LookAgain?

    public init(session: URLSession = .shared, lookAgain: LookAgain? = nil, inspect: @escaping Inspect) {
        self.session = session
        self.play = lookAgain
        self.inspect = inspect
    }

    public func analyze(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        stream { await run(page, report: $0) }
    }

    public func lookAgain(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        stream { await playAndRead(page, report: $0) }
    }

    private func stream(_ work: @escaping @Sendable (@escaping @Sendable (PageAnalysis) -> Void) async -> Void) -> AsyncStream<PageAnalysis> {
        AsyncStream { continuation in
            let task = Task {
                await work { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func playAndRead(_ page: SentPage, report: (PageAnalysis) -> Void) async {
        guard let play else { return report(.found([])) }
        report(.playing)
        let played = await play(page)
        guard !Task.isCancelled else { return }
        let refusals = Refusals()
        let found = await candidates(on: page.played(played), reading: nil, refusals: refusals) { _ in }
        guard !Task.isCancelled else { return }
        report(found.isEmpty && refusals.any ? .needsSignIn : .found(found))
    }

    private func run(_ page: SentPage, report: (PageAnalysis) -> Void) async {
        if HLSVersions.isPlaylist(page.url) { return report(await linkedPlaylist(page, label: page.url.lastPathComponent)) }
        let refusals = Refusals()
        let linked: LinkInspection?
        do {
            linked = try await inspect(page.url, pageOptions(page))
        } catch {
            refusals.note(error)
            linked = nil
        }
        if let linked, !linked.isWebPage {
            if HLSVersions.isPlaylist(page.url, contentType: linked.contentType) {
                return report(await linkedPlaylist(page, label: linked.fileName))
            }
            let version = Version(source: .file(page.url), contentType: linked.contentType, totalBytes: linked.totalBytes)
            guard Self.kind(of: linked) != nil else { return report(.plainFile(page.url)) }
            return report(.found([Candidate(label: linked.fileName, versions: [version])]))
        }

        let found = await candidates(on: page, reading: await read(page, refusals: refusals), refusals: refusals, report: report)
        if found.isEmpty, refusals.any { return report(.needsSignIn) }
        if found.isEmpty, play != nil { return await playAndRead(page, report: report) }
        report(.found(found))
    }

    private func linkedPlaylist(_ page: SentPage, label: String) async -> PageAnalysis {
        let refusals = Refusals()
        let candidates = await playlistCandidates([page.url], page: page, refusals: refusals, label: label, thumbnail: nil)
        return candidates.isEmpty && refusals.any ? .needsSignIn : .found(candidates)
    }

    private func candidates(on page: SentPage, reading: HTMLReader?, refusals: Refusals, report: (PageAnalysis) -> Void) async -> [Candidate] {
        var players = Players()
        for media in page.scan { players.add(media, from: "page") }
        for media in reading?.media ?? [] { players.add(media, from: "html") }
        let shown = Set(players.list.flatMap(\.sources).map(\.url))
        let watchedFiles = Set(page.watched.filter { $0.kind == .file }.map(\.url)).subtracting(shown)
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
                    let inspection: LinkInspection
                    do {
                        inspection = try await inspect(url, options)
                    } catch {
                        if !watchedFiles.contains(url) { refusals.note(error) }
                        return (url, nil)
                    }
                    guard Self.kind(of: inspection) != nil else { return (url, nil) }
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
        let playlists = page.watched.filter { HLSVersions.isPlaylist($0.url, contentType: $0.contentType) }.map(\.url)
        let streamed = await playlistCandidates(playlists, page: page, refusals: refusals, label: label, thumbnail: reading?.image ?? page.scan.lazy.compactMap(\.poster).first)
        return Self.merged(kept + streamed)
    }

    private func playlistCandidates(_ urls: [URL], page: SentPage, refusals: Refusals, label: String, thumbnail: URL?) async -> [Candidate] {
        let options = mediaOptions(page)
        var parsed: [(URL, Playlist)] = []
        for url in urls where !parsed.contains(where: { $0.0 == url }) {
            if let playlist = await playlist(at: url, options: options, refusals: refusals) { parsed.append((url, playlist)) }
        }
        var covered = Set<String>()
        for case let (_, .master(master)) in parsed {
            master.variants.forEach { covered.insert(Self.withoutQuery($0.url)) }
            master.audio.compactMap(\.url).forEach { covered.insert(Self.withoutQuery($0)) }
        }
        var candidates: [Candidate] = []
        for (url, playlist) in parsed {
            switch playlist {
            case .master(let master):
                let found = await withTaskGroup(of: (Int, Version?, Double).self) { group in
                    for (index, variant) in master.variants.enumerated() {
                        group.addTask {
                            guard case .media(let media) = await self.playlist(at: variant.url, options: options, refusals: refusals) else { return (index, nil, 0) }
                            return (index, HLSVersions.version(of: media, variant: variant, audioIsSeparate: HLSVersions.audioIsSeparate(for: variant, in: master)), media.duration)
                        }
                    }
                    var results: [(Int, Version?, Double)] = []
                    for await result in group { results.append(result) }
                    return results.sorted { $0.0 < $1.0 }
                }
                let versions = found.compactMap(\.1)
                guard !versions.isEmpty else { continue }
                candidates.append(Candidate(label: label, thumbnail: thumbnail, duration: found.map(\.2).max(), versions: versions))
            case .media(let media):
                guard !covered.contains(Self.withoutQuery(url)), let version = HLSVersions.version(of: media, variant: nil) else { continue }
                candidates.append(Candidate(label: label, thumbnail: thumbnail, duration: media.duration, versions: [version]))
            }
        }
        return candidates
    }

    private static func withoutQuery(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.query = nil
        parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }

    static let sameLengthWithin = 2.0

    static func merged(_ candidates: [Candidate]) -> [Candidate] {
        var groups: [[Candidate]] = []
        for candidate in candidates {
            if let length = candidate.duration,
               let index = groups.firstIndex(where: { $0.contains { other in other.duration.map { abs($0 - length) <= sameLengthWithin } ?? false } }) {
                groups[index].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        return groups.map { group in
            guard group.count > 1, var first = group.first else { return group[0] }
            first.thumbnail = group.lazy.compactMap(\.thumbnail).first
            first.duration = group.compactMap(\.duration).max()
            first.versions = distinct(group.flatMap(\.versions))
            return first
        }
    }

    private static func distinct(_ versions: [Version]) -> [Version] {
        var seen = Set<URL>()
        return versions.enumerated()
            .filter { seen.insert($0.element.source.url).inserted }
            .sorted { ($0.element.height ?? 0, $0.offset) < ($1.element.height ?? 0, $1.offset) }
            .map(\.element)
    }

    private func playlist(at url: URL, options: RequestOptions, refusals: Refusals) async -> Playlist? {
        var request = URLRequest(url: url)
        if let agent = options.userAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        if let referrer = options.referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
        if !options.cookies.isEmpty {
            request.setValue(options.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        guard let (data, http) = await fetch(request, refusals: refusals) else { return nil }
        return try? M3U8Parser.parse(String(decoding: data, as: UTF8.self), base: http.url ?? url)
    }

    private func fetch(_ request: URLRequest, refusals: Refusals) async -> (Data, HTTPURLResponse)? {
        var request = request
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        refusals.note(status: http.statusCode)
        guard (200..<300).contains(http.statusCode), data.count <= Self.largestPage else { return nil }
        return (data, http)
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

    public static func site(of url: URL) -> String {
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

    private func read(_ page: SentPage, refusals: Refusals) async -> HTMLReader? {
        var request = URLRequest(url: page.url)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let agent = page.userAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        if !page.cookies.isEmpty {
            request.setValue(page.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        guard let (data, http) = await fetch(request, refusals: refusals),
              LinkInspection.isWebPage(mimeType: http.value(forHTTPHeaderField: "Content-Type")) else { return nil }
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

final class Refusals: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false

    var any: Bool { lock.withLock { refused } }

    func note(_ error: any Error) {
        guard let error = error as? DownloadError, error == .needsSignIn || error == .forbidden else { return }
        lock.withLock { refused = true }
    }

    func note(status: Int) {
        guard status == 401 || status == 403 else { return }
        lock.withLock { refused = true }
    }
}
