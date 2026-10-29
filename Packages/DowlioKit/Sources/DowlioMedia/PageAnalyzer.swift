import DowlioCore
import Foundation

public struct PageAnalyzer: Sendable {
    public typealias Inspect = @Sendable (URL, RequestOptions) async throws -> LinkInspection

    static let largestPage = 8 * 1024 * 1024

    private let inspect: Inspect
    private let session: URLSession
    private let play: LookAgain?
    private let readers: [any SiteReader]
    private let readerFailed: @Sendable (ReaderFailure) -> Void
    private let sizes: SizeCheck

    public init(
        session: URLSession = .shared,
        lookAgain: LookAgain? = nil,
        readers: [any SiteReader] = SiteReaders.all,
        readerFailed: @escaping @Sendable (ReaderFailure) -> Void = ReaderFailure.log,
        inspect: @escaping Inspect
    ) {
        self.session = session
        self.play = lookAgain
        self.readers = readers
        self.readerFailed = readerFailed
        self.inspect = inspect
        self.sizes = SizeCheck(inspect: inspect)
    }

    public func analyze(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        stream { await run(page.withoutControlLabels, report: $0) }
    }

    public func lookAgain(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        stream { await playAndRead(page.withoutControlLabels, report: $0) }
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
        let seen = page.played(played)
        let found = await candidates(on: seen, reading: nil, refusals: refusals) { _ in }
        guard !Task.isCancelled else { return }
        let agent = page.userAgent == nil ? seen.userAgent : nil
        report(found.isEmpty && refusals.any ? .needsSignIn : .found(found.map { $0.requested(by: agent) }))
    }

    private func run(_ page: SentPage, report: (PageAnalysis) -> Void) async {
        if DASHVersions.isStream(page.url) {
            return report(await linkedPlaylist(page, label: page.url.lastPathComponent))
        }
        let refusals = Refusals()
        let linked: LinkInspection?
        do {
            linked = try await inspect(page.url, pageOptions(page))
        } catch {
            refusals.note(error)
            linked = nil
        }
        if let linked, !linked.isWebPage {
            if DASHVersions.isStream(page.url, contentType: linked.contentType) {
                return report(await linkedPlaylist(page, label: linked.fileName))
            }
            let version = Version(source: .file(page.url), contentType: linked.contentType, totalBytes: linked.totalBytes)
            guard Self.kind(of: linked) != nil else { return report(.plainFile(page.url)) }
            let candidate = Candidate(label: linked.fileName, versions: [version])
            return report(.found([candidate.withExtractedAudio(splittable: linked.splitsIntoSegments ? [page.url] : [])]))
        }

        let reading = await read(page, refusals: refusals)
        async let fromSite = readSite(page, reading: reading, refusals: refusals)
        let fromPage = await candidates(on: page, reading: reading, refusals: refusals, report: report)
        let found = Self.joined(fromPage, await fromSite, on: page)
        if found.isEmpty, refusals.any { return report(.needsSignIn) }
        if found.isEmpty, play != nil { return await playAndRead(page, report: report) }
        report(.found(found))
    }

    private func linkedPlaylist(_ page: SentPage, label: String) async -> PageAnalysis {
        let refusals = Refusals()
        let candidates = await sized(await streamCandidates([page.url], page: page, refusals: refusals, label: label, thumbnail: nil, fragments: StreamFragments()), on: page)
        return candidates.isEmpty && refusals.any ? .needsSignIn : .found(candidates.map { $0.withExtractedAudio(splittable: []) })
    }

    public func probe(_ candidate: Candidate, on sent: SentPage) async -> Candidate {
        let page = sent.withoutControlLabels
        let files = candidate.unprobed.filter { $0.kind == .file }.map { ScannedMedia(url: $0.url, kind: MediaFile.kind(of: $0.url, contentType: $0.contentType) ?? .video) }
        let streams = candidate.unprobed.filter { $0.kind == .manifest }.map(\.url)
        let context = PageContext(page: page, reading: nil, label: candidate.label, shown: Set(files.map(\.url)), watchedFiles: [])
        let probed = await probe(PageLayout.Bucket(files: files, streams: streams), in: context, refusals: Refusals())
        let merged = Self.merged(context.fragments.withoutListedFragments(in: probed.candidates))
        var found = await sized(merged, on: page).first?.withExtractedAudio(splittable: probed.splittable) ?? candidate
        found.label = candidate.label
        found.thumbnail = candidate.thumbnail ?? found.thumbnail
        found.isOnScreen = candidate.isOnScreen
        found.isOther = candidate.isOther
        found.unprobed = []
        return found
    }

    private struct PageContext: Sendable {
        var page: SentPage
        var reading: HTMLReader?
        var label: String
        var shown: Set<URL>
        var watchedFiles: Set<URL>
        var fragments = StreamFragments()
    }

    private func candidates(on page: SentPage, reading: HTMLReader?, refusals: Refusals, report: (PageAnalysis) -> Void) async -> [Candidate] {
        var players = Players()
        for media in page.scan { players.add(media, from: "page") }
        for media in reading?.media ?? [] { players.add(media, from: "html") }
        let streams = page.watched
            .filter { $0.kind == .manifest || DASHVersions.isStream($0.url, contentType: $0.contentType) }
            .map(\.url)
        let shown = Set(players.list.flatMap(\.sources).map(\.url))
        let watchedFiles = Set(page.watched.filter { $0.kind == .file }.map(\.url)).subtracting(shown)
        for request in page.watched where request.kind == .file && !StreamFragments.isNamedLikeAFragment(request.url, nextTo: streams) {
            let kind = MediaFile.kind(of: request.url, contentType: request.contentType) ?? .video
            if let group = PageLayout.matchingPlayer(for: request.url, in: page.players) {
                players.add(ScannedMedia(url: request.url, kind: kind, group: group), from: "page")
            } else {
                players.add(ScannedMedia(url: request.url, kind: kind), from: "watched")
            }
        }
        let layout = PageLayout(page: page, players: players.list.map { ($0.group, $0.sources) }, streams: streams)
        let label = Self.label(of: page, reading: reading)
        let fragments = StreamFragments()
        let context = PageContext(page: page, reading: reading, label: label, shown: shown, watchedFiles: watchedFiles, fragments: fragments)
        let placeholders = layout.buckets.map { placeholder(of: $0, in: context) }
        if !placeholders.isEmpty { report(.looking(placeholders)) }

        let probedCount = layout.isFeed ? PageLayout.probedAtOnce : layout.buckets.count
        let probed = await withTaskGroup(of: (Int, ProbedBucket).self) { group in
            for (index, bucket) in layout.buckets.enumerated().prefix(probedCount) {
                group.addTask { (index, await self.probe(bucket, in: context, refusals: refusals)) }
            }
            var found: [Int: ProbedBucket] = [:]
            for await (index, result) in group { found[index] = result }
            return found
        }
        let splittable = probed.values.reduce(into: Set<URL>()) { $0.formUnion($1.splittable) }
        var found: [Candidate]
        if layout.isFeed {
            found = layout.buckets.indices.flatMap { index -> [Candidate] in
                guard let result = probed[index] else {
                    var waiting = placeholders[index]
                    waiting.unprobed = layout.buckets[index].unprobed
                    return [waiting]
                }
                return Self.merged(result.candidates).enumerated().map { offset, candidate in
                    var placed = candidate
                    placed.isOther = layout.buckets[index].isOther
                    placed.isOnScreen = index == 0 && offset == 0 && layout.onScreen != nil
                    return placed
                }
            }
        } else {
            found = Self.merged(layout.buckets.indices.flatMap { probed[$0]?.candidates ?? [] })
        }
        return await sized(fragments.withoutListedFragments(in: found), on: page).map { $0.withExtractedAudio(splittable: splittable) }
    }

    private static func label(of page: SentPage, reading: HTMLReader?) -> String {
        reading?.title ?? page.title ?? page.url.host() ?? page.url.absoluteString
    }

    private struct SiteFinding: Sendable {
        var candidates: [Candidate]
        var isPost: Bool
    }

    private func readSite(_ page: SentPage, reading: HTMLReader?, refusals: Refusals) async -> SiteFinding? {
        guard let reader = readers.first(where: { $0.recognises(page.url) }) else { return nil }
        let site = page.url.host(percentEncoded: false) ?? page.url.absoluteString
        let sitePage = SitePage(url: page.url, embeddedJSON: page.embeddedJSON + (reading?.embeddedJSON ?? []), html: reading?.html, cookies: page.cookies) { url in
            try await self.readerData(at: url, for: page)
        }
        let videos: [SiteVideo]
        do {
            videos = try await reader.read(sitePage)
        } catch {
            readerFailed(ReaderFailure(reader: reader.name, site: site, reason: String(describing: error)))
            return nil
        }
        let fallback = Self.label(of: page, reading: reading)
        var found: [Candidate] = []
        for video in videos {
            let label = video.label ?? Self.player(lasting: video.duration, on: page)?.label ?? fallback
            found += await candidates(of: video, on: page, label: label, refusals: refusals)
        }
        guard !found.isEmpty else {
            readerFailed(ReaderFailure(reader: reader.name, site: site, reason: "found nothing"))
            return nil
        }
        return SiteFinding(candidates: await sized(found, on: page).map { $0.withExtractedAudio(splittable: []) }, isPost: reader.post(in: page.url) != nil)
    }

    private func sized(_ candidates: [Candidate], on page: SentPage) async -> [Candidate] {
        await sizes.sized(candidates) { url, version in
            var options = mediaOptions(page, for: url)
            if let referrer = version.referrer { options.referrer = referrer }
            if let agent = version.userAgent { options.userAgent = agent }
            return options
        }
    }

    private static func player(lasting duration: Double?, on page: SentPage) -> ScannedPlayer? {
        let matching = page.players.filter { sameLength($0.duration, duration) }
        return matching.count == 1 ? matching[0] : nil
    }

    private func candidates(of video: SiteVideo, on page: SentPage, label: String, refusals: Refusals) async -> [Candidate] {
        if let restriction = video.restriction {
            return [Candidate(label: label, thumbnail: video.thumbnail, duration: video.duration, versions: [], restriction: restriction)]
        }
        let streamed = await streamCandidates(video.streams, page: page, refusals: refusals, label: label, thumbnail: video.thumbnail, fragments: StreamFragments())
        let versions = Self.distinct(video.versions + streamed.flatMap(\.versions))
        guard !versions.isEmpty else { return streamed.filter { $0.restriction != nil } }
        return [Candidate(
            label: label, thumbnail: video.thumbnail ?? streamed.lazy.compactMap(\.thumbnail).first,
            duration: video.duration ?? streamed.compactMap(\.duration).max(), versions: versions
        )]
    }

    private func readerData(at url: URL, for page: SentPage) async throws -> Data {
        var request = request(for: url, options: mediaOptions(page, for: url))
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SiteReaderError.unreadable }
        guard (200..<300).contains(http.statusCode) else { throw SiteReaderError.refused(status: http.statusCode) }
        guard data.count <= Self.largestPage else { throw SiteReaderError.unreadable }
        return data
    }

    private static func joined(_ fromPage: [Candidate], _ fromSite: SiteFinding?, on page: SentPage) -> [Candidate] {
        guard let fromSite else { return fromPage }
        if fromSite.isPost { return fromSite.candidates }
        var rows = fromPage
        let players = PageLayout.ordered(page.players)
        var taken = Set<Int>()
        var placed: [(rank: Int, candidate: Candidate)] = []
        for candidate in fromSite.candidates {
            let ids = candidate.addressIDs
            let shared = ids.isEmpty ? nil : rows.firstIndex { !$0.addressIDs.isDisjoint(with: ids) }
            if let index = shared ?? rows.firstIndex(where: { $0.restriction == nil && Self.sameLength($0.duration, candidate.duration) }) {
                rows[index] = rows[index].joining(candidate)
            } else if let rank = players.indices.first(where: { !taken.contains($0) && Self.sameLength(players[$0].duration, candidate.duration) }) {
                taken.insert(rank)
                var labelled = candidate
                labelled.label = players[rank].label ?? candidate.label
                placed.append((rank, labelled))
            } else {
                placed.append((players.count, candidate))
            }
        }
        let ordered = placed.sorted { $0.rank < $1.rank }
        rows += ordered.map(\.candidate)
        let showing = players.first.map { $0.isPlaying || $0.visibility > 0 } ?? false
        if showing, ordered.first?.rank == 0, let shown = ordered.first?.candidate { return Self.onScreenFirst(shown, in: rows) }
        return rows
    }

    private static func onScreenFirst(_ shown: Candidate, in rows: [Candidate]) -> [Candidate] {
        guard rows.count > 1, !rows.contains(where: \.isOnScreen), let index = rows.firstIndex(of: shown) else { return rows }
        var rows = rows
        var first = rows.remove(at: index)
        first.isOnScreen = true
        rows.insert(first, at: 0)
        return rows
    }

    private struct ProbedBucket: Sendable {
        var candidates: [Candidate] = []
        var splittable: Set<URL> = []
    }

    private func placeholder(of bucket: PageLayout.Bucket, in place: PageContext) -> Candidate {
        Candidate(
            label: bucket.player?.label ?? place.label,
            thumbnail: bucket.player?.poster ?? bucket.files.lazy.compactMap(\.poster).first ?? place.reading?.image,
            duration: bucket.player?.duration ?? bucket.files.lazy.compactMap(\.duration).first ?? place.reading?.duration,
            versions: [],
            isOther: bucket.isOther
        )
    }

    private func probe(_ bucket: PageLayout.Bucket, in place: PageContext, refusals: Refusals) async -> ProbedBucket {
        let probes = await withTaskGroup(of: (URL, Probe).self) { group in
            for media in bucket.files {
                group.addTask { [inspect] in
                    let url = media.url
                    let options = mediaOptions(place.page, for: url)
                    let inspection: LinkInspection
                    do {
                        inspection = try await inspect(url, options)
                    } catch {
                        if !place.watchedFiles.contains(url) { refusals.note(error) }
                        return (url, Probe())
                    }
                    guard Self.kind(of: inspection) != nil else { return (url, Probe()) }
                    return (url, Probe(version: Version(
                        source: .file(url), contentType: inspection.contentType, totalBytes: inspection.totalBytes,
                        height: media.height ?? MediaFile.height(in: url.path), codecs: media.codecs ?? MediaFile.codecs(in: url.path),
                        referrer: place.page.referrer(of: url)
                    ), splitsIntoSegments: inspection.splitsIntoSegments))
                }
            }
            var found: [URL: Probe] = [:]
            for await (url, probe) in group { found[url] = probe }
            return found
        }
        let shell = placeholder(of: bucket, in: place)
        var result = ProbedBucket(splittable: Set(probes.filter(\.value.splitsIntoSegments).keys))
        let versions = Self.distinct(bucket.files.compactMap { probes[$0.url]?.version }.filter { version in
            place.shown.contains(version.source.url) || !Self.looksLikeAnAd(version, on: place.page.url)
        })
        if !versions.isEmpty {
            var files = shell
            files.versions = versions
            result.candidates.append(files)
        }
        let thumbnail = bucket.player?.poster ?? place.reading?.image ?? place.page.scan.lazy.compactMap(\.poster).first
        let streamed = await streamCandidates(bucket.streams, page: place.page, refusals: refusals, label: shell.label, thumbnail: thumbnail, fragments: place.fragments)
        result.candidates += streamed.map { candidate in
            var placed = candidate
            if let duration = bucket.player?.duration, placed.duration == nil { placed.duration = duration }
            return placed
        }
        return result
    }

    private func streamCandidates(
        _ urls: [URL], page: SentPage, refusals: Refusals, label: String, thumbnail: URL?, fragments: StreamFragments
    ) async -> [Candidate] {
        var parsed: [(URL, Playlist)] = []
        var candidates: [Candidate] = []
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard let (data, http) = await fetch(request(for: url, options: mediaOptions(page, for: url)), refusals: refusals) else { continue }
            if let playlist = Self.playlist(in: data, from: http, at: url) {
                parsed.append((url, playlist))
            } else if let manifest = try? MPDParser.parse(data, base: http.url ?? url),
                      let candidate = DASHVersions.candidate(of: manifest, label: label, thumbnail: thumbnail) {
                candidates.append(candidate.referred(by: page.referrer(of: url)))
            }
        }
        var covered = Set<String>()
        for case let (_, .master(master)) in parsed {
            master.variants.forEach { covered.insert(Self.withoutQuery($0.url)) }
            master.audio.compactMap(\.url).forEach { covered.insert(Self.withoutQuery($0)) }
        }
        var coveredStreams = Set<String>()
        let mastersFirst = parsed.filter { $0.1.isMaster } + parsed.filter { !$0.1.isMaster }
        for (url, playlist) in mastersFirst {
            let options = mediaOptions(page, for: url)
            let referrer = page.referrer(of: url)
            switch playlist {
            case .master(let master):
                if master.isProtected {
                    candidates.append(Candidate(label: label, thumbnail: thumbnail, versions: [], restriction: .protected))
                    continue
                }
                let audioPlaylists = await audioPlaylists(of: master, options: options, refusals: refusals)
                let found = await withTaskGroup(of: VariantPlaylist.self) { group in
                    for (index, variant) in master.variants.enumerated() {
                        group.addTask {
                            guard case .media(let media) = await self.playlist(at: variant.url, options: options, refusals: refusals) else {
                                return VariantPlaylist(index: index)
                            }
                            let audio = master.defaultAudio(for: variant)?.url.flatMap { audioPlaylists[$0] }
                            return VariantPlaylist(index: index, media: media, version: HLSVersions.version(of: media, variant: variant, audio: audio))
                        }
                    }
                    var results: [VariantPlaylist] = []
                    for await result in group { results.append(result) }
                    return results.sorted { $0.index < $1.index }
                }
                let playlists = found.compactMap(\.media) + audioPlaylists.values
                playlists.forEach(fragments.note)
                playlists.forEach { coveredStreams.insert($0.fragmentNames) }
                let audio = Self.audioVersions(of: master, playlists: audioPlaylists)
                let videos = found.compactMap(\.version)
                let candidate = Candidate(
                    label: label, thumbnail: thumbnail, duration: found.compactMap(\.media?.duration).max(),
                    versions: videos.isEmpty ? [] : videos + audio
                )
                if let shown = candidate.offeredOrRestricted(by: playlists) { candidates.append(shown.referred(by: referrer)) }
            case .media(let media):
                fragments.note(media)
                guard !covered.contains(Self.withoutQuery(url)), !coveredStreams.contains(media.fragmentNames) else { continue }
                let versions = HLSVersions.version(of: media, variant: nil).map { [$0] } ?? []
                let candidate = Candidate(label: label, thumbnail: thumbnail, duration: media.duration, versions: versions)
                if let shown = candidate.offeredOrRestricted(by: [media]) { candidates.append(shown.referred(by: referrer)) }
            }
        }
        return candidates
    }

    private func audioPlaylists(of master: MasterPlaylist, options: RequestOptions, refusals: Refusals) async -> [URL: MediaPlaylist] {
        await withTaskGroup(of: (URL, MediaPlaylist?).self) { group in
            for url in master.audioAddresses {
                group.addTask {
                    guard case .media(let media) = await self.playlist(at: url, options: options, refusals: refusals) else { return (url, nil) }
                    return (url, media)
                }
            }
            var found: [URL: MediaPlaylist] = [:]
            for await (url, media) in group { found[url] = media }
            return found
        }
    }

    private static func audioVersions(of master: MasterPlaylist, playlists: [URL: MediaPlaylist]) -> [Version] {
        master.audioAddresses.compactMap { url in
            guard let media = playlists[url], let listed = master.audio.first(where: { $0.url == url }) else { return nil }
            return HLSVersions.audioVersion(of: media, language: listed.name, codecs: master.codecs(ofAudioGroup: listed.groupID))
        }
    }

    static func withoutQuery(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.query = nil
        parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }

    static let sameLengthWithin = 2.0

    private static func sameLength(_ one: Double?, _ other: Double?) -> Bool {
        guard let one, let other else { return false }
        return abs(one - other) <= sameLengthWithin
    }

    static func merged(_ candidates: [Candidate]) -> [Candidate] {
        var groups: [[Candidate]] = []
        for candidate in candidates {
            if candidate.restriction == nil, let length = candidate.duration,
               let index = groups.firstIndex(where: { $0.contains { other in other.restriction == nil && other.duration.map { abs($0 - length) <= sameLengthWithin } ?? false } }) {
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

    static func distinct(_ versions: [Version]) -> [Version] {
        var seen = Set<String>()
        var rows: [Version] = []
        var rowOf: [String: Int] = [:]
        for version in versions where seen.insert(sameFile(version)).inserted {
            guard let key = sameRow(version) else {
                rows.append(version)
                continue
            }
            if let index = rowOf[key] {
                if case .media = rows[index].source, case .file = version.source { rows[index] = version }
            } else {
                rowOf[key] = rows.count
                rows.append(version)
            }
        }
        return rows.enumerated()
            .sorted { ($0.element.height ?? 0, $0.offset) < ($1.element.height ?? 0, $1.offset) }
            .map(\.element)
    }

    private static func sameRow(_ version: Version) -> String? {
        guard !version.isAudio, !version.isExtractedAudio, let height = version.height,
              let codec = MediaCodecs.videoCodec(in: version.codecs) else { return nil }
        return "\(height) \(codec) \(version.container)"
    }

    private static func sameFile(_ version: Version) -> String {
        guard case .file(let url) = version.source, let size = version.totalBytes else { return version.source.url.absoluteString }
        return "\(withoutQuery(url)) \(size)"
    }

    private func playlist(at url: URL, options: RequestOptions, refusals: Refusals) async -> Playlist? {
        guard let (data, http) = await fetch(request(for: url, options: options), refusals: refusals) else { return nil }
        return Self.playlist(in: data, from: http, at: url)
    }

    private static func playlist(in data: Data, from http: HTTPURLResponse, at url: URL) -> Playlist? {
        try? M3U8Parser.parse(String(decoding: data, as: UTF8.self), base: http.url ?? url)
    }

    private func request(for url: URL, options: RequestOptions) -> URLRequest {
        var request = URLRequest(url: url)
        if let agent = options.userAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        if let referrer = options.referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
        if let origin = url.crossOrigin(from: options.referrer) { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if !options.cookies.isEmpty {
            request.setValue(options.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        return request
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
            var group: Int?
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
                list.append(Player(key: key, group: origin == "page" ? media.group : nil, sources: [media]))
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
        for (name, value) in ["Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document", "Sec-Fetch-Site": "none"] {
            request.setValue(value, forHTTPHeaderField: name)
        }
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

    private func mediaOptions(_ page: SentPage, for url: URL) -> RequestOptions {
        var options = pageOptions(page)
        options.referrer = page.referrer(of: url) ?? page.url
        return options
    }
}

private struct VariantPlaylist: Sendable {
    var index: Int
    var media: MediaPlaylist?
    var version: Version?
}

private extension SentPage {
    func referrer(of url: URL) -> URL? {
        watched.first { $0.url == url }?.referrer
    }
}

private extension Version {
    var container: String {
        switch source {
        case .file(let url): url.pathExtension.lowercased()
        case .media(let media): media.fileExtension
        }
    }
}

private extension Playlist {
    var isMaster: Bool {
        if case .master = self { return true }
        return false
    }
}

private extension Candidate {
    func joining(_ other: Candidate) -> Candidate {
        var joined = self
        joined.versions = PageAnalyzer.distinct(versions.filter { !$0.isExtractedAudio } + other.versions)
        joined.thumbnail = thumbnail ?? other.thumbnail
        joined.duration = duration ?? other.duration
        joined.unprobed = []
        return joined
    }

    var addressIDs: Set<String> {
        let urls = [thumbnail].compactMap { $0 } + versions.filter { !$0.isExtractedAudio }.map(\.source.url) + unprobed.map(\.url)
        return urls.reduce(into: Set<String>()) { $0.formUnion(PageLayout.ids(in: $1)) }
    }

    func referred(by referrer: URL?) -> Candidate {
        guard let referrer else { return self }
        var referred = self
        referred.versions = versions.map { version in
            var version = version
            version.referrer = referrer
            return version
        }
        return referred
    }

    func requested(by agent: String?) -> Candidate {
        guard let agent else { return self }
        var requested = self
        requested.versions = versions.map { version in
            var version = version
            version.userAgent = agent
            return version
        }
        return requested
    }

    func offeredOrRestricted(by playlists: [MediaPlaylist]) -> Candidate? {
        guard versions.isEmpty else { return self }
        let found = playlists.compactMap(HLSVersions.restriction)
        guard let restriction = found.contains(.protected) ? .protected : found.first else { return nil }
        var restricted = self
        restricted.restriction = restriction
        return restricted
    }
}

private struct Probe: Sendable {
    var version: Version?
    var splitsIntoSegments = false
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
