import DowlioCore
import Foundation
import VideoToolbox

public struct PageAnalyzer: Sendable {
    public typealias Inspect = @Sendable (URL, RequestOptions) async throws -> LinkInspection

    static let largestPage = 8 * 1024 * 1024

    private let inspect: Inspect
    private let session: URLSession
    private let play: LookAgain?
    private let longestLooking: Duration
    private let readers: [any SiteReader]
    private let readerFailed: @Sendable (ReaderFailure) -> Void
    private let sizes: SizeCheck
    private let identity: BrowserIdentity
    private let cooldown: HostCooldown
    private let ytdlp: YTDLPRunner?
    private let decodesAV1: Bool
    private let subtitles: @Sendable () -> SubtitlePreference

    @TaskLocal static var reachesLocalNetwork = false

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    public init(
        session: URLSession = PageAnalyzer.makeSession(),
        identity: BrowserIdentity = BrowserIdentity(userAgent: nil),
        cooldown: HostCooldown = HostCooldown(),
        lookAgain: LookAgain? = nil,
        lookingFor longestLooking: Duration = .seconds(15),
        readers: [any SiteReader] = SiteReaders.all,
        readerFailed: @escaping @Sendable (ReaderFailure) -> Void = ReaderFailure.log,
        ytdlp: YTDLPRunner? = nil,
        decodesAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
        subtitles: @escaping @Sendable () -> SubtitlePreference = { .off },
        inspect: @escaping Inspect
    ) {
        self.subtitles = subtitles
        self.ytdlp = ytdlp
        self.decodesAV1 = decodesAV1
        self.session = session
        self.identity = identity
        self.cooldown = cooldown
        self.play = lookAgain
        self.longestLooking = longestLooking
        self.readers = readers
        self.readerFailed = readerFailed
        let guarded: Inspect = { url, options in
            guard Self.mayReach(url) else { throw URLError(.cannotConnectToHost) }
            return try await inspect(url, options)
        }
        self.inspect = guarded
        self.sizes = SizeCheck(inspect: guarded)
    }

    static func mayReach(_ url: URL) -> Bool {
        reachesLocalNetwork || !LocalAddress.isLocal(url)
    }

    private static func within<T>(_ page: SentPage, _ work: () async -> T) async -> T {
        await $reachesLocalNetwork.withValue(LocalAddress.isLocal(page.url) || LocalAddress.isLocal(page.framedBy)) { await work() }
    }

    public func analyze(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        let (identified, agent) = identified(page)
        return stream(stampingVersionsWith: agent) { report in await Self.within(identified) { await run(identified, report: report) } }
    }

    public func lookAgain(_ page: SentPage) -> AsyncStream<PageAnalysis> {
        let (identified, agent) = identified(page)
        return stream(stampingVersionsWith: agent) { report in await Self.within(identified) { await playAndRead(identified, report: report) } }
    }

    private func identified(_ page: SentPage) -> (page: SentPage, addedAgent: String?) {
        var identified = page.withoutControlLabels
        guard identified.userAgent == nil, let agent = identity.userAgent else { return (identified, nil) }
        identified.userAgent = agent
        return (identified, agent)
    }

    private func stream(
        stampingVersionsWith agent: String?, _ work: @escaping @Sendable (@escaping @Sendable (PageAnalysis) -> Void) async -> Void
    ) -> AsyncStream<PageAnalysis> {
        AsyncStream { continuation in
            let task = Task {
                await work { continuation.yield($0.requested(by: agent)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func playAndRead(_ page: SentPage, report: (PageAnalysis) -> Void) async {
        guard play != nil else { return report(.found([])) }
        report(.playing)
        guard let found = await lookedAgain(page, within: nil) else { return }
        let agent = page.userAgent == nil ? found.agent : nil
        if found.candidates.isEmpty, found.refusals.blocked { return report(.blocked) }
        report(found.candidates.isEmpty && found.refusals.any ? .needsSignIn : .found(found.candidates.map { $0.requested(by: agent) }))
    }

    private struct LookAgainResult {
        var candidates: [Candidate]
        var agent: String?
        var refusals: Refusals
    }

    public func reading(_ played: PlayedPage, of page: SentPage) async -> PageAnalysis {
        await Self.within(page) { await readingWithin(played, of: page) }
    }

    private func readingWithin(_ played: PlayedPage, of page: SentPage) async -> PageAnalysis {
        let identified = identified(page).page
        guard let found = await read(played, of: identified) else { return .found([]) }
        if found.candidates.isEmpty, found.refusals.blocked { return .blocked }
        if found.candidates.isEmpty, found.refusals.any { return .needsSignIn }
        let agent = identified.userAgent ?? found.agent
        return .found(found.candidates.map { $0.requested(by: agent) })
    }

    private func lookedAgain(_ page: SentPage, within limit: Duration?) async -> LookAgainResult? {
        guard let play else { return nil }
        let played = await Self.played(page, by: play, within: limit)
        return await read(played, of: page)
    }

    private func read(_ played: PlayedPage, of page: SentPage) async -> LookAgainResult? {
        guard !Task.isCancelled else { return nil }
        let refusals = Refusals()
        let seen = page.played(played).withoutControlLabels
        if played.html.map(BlockedPage.isChallenge) == true { refusals.noteBlocked() }
        let reading = played.html.map { HTMLReader($0, base: page.url) }
        async let fromSite = readSite(seen, reading: reading, refusals: refusals)
        let fromPage = await candidates(on: seen, reading: reading, refusals: refusals) { _ in }
        let found = Self.joined(fromPage, await fromSite, on: seen)
        guard !Task.isCancelled else { return nil }
        return LookAgainResult(candidates: found, agent: seen.userAgent, refusals: refusals)
    }

    private static func played(_ page: SentPage, by play: @escaping LookAgain, within limit: Duration?) async -> PlayedPage {
        guard let limit else { return await play(page) }
        let playing = Task { await play(page) }
        let timer = Task {
            try? await Task.sleep(for: limit)
            playing.cancel()
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler { await playing.value } onCancel: { playing.cancel() }
    }

    private func run(_ page: SentPage, report: (PageAnalysis) -> Void) async {
        if let link = YouTubeLink(page.url) {
            return report(await withYTDLP(page, opensAsAudio: link.isMusic))
        }
        let start = ContinuousClock.now
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
        async let fromFrames = frameCandidates(on: page, reading: reading, within: longestLooking - (ContinuousClock.now - start))
        let steps = await quickSteps(on: page, reading: reading, refusals: refusals, report: report)
        let framed = await fromFrames
        var found = framed.isEmpty ? steps.found : Self.merged(steps.found + framed)
        switch await youTubeEmbeds(in: reading, on: page, within: longestLooking - (ContinuousClock.now - start)) {
        case .found(let embedded) where !embedded.isEmpty:
            found = Self.merged(found + embedded)
        case .needsTools where found.isEmpty:
            return report(.needsTools)
        default:
            break
        }
        if found.isEmpty, let ytdlp, await ytdlp.isInstalled {
            let tried = await withYTDLP(page, opensAsAudio: false)
            switch tried {
            case .found(let candidates) where candidates.contains(where: Self.isOffered):
                return report(.found(candidates.filter(Self.isOffered)))
            case .ytdlpFailed(.private), .ytdlpFailed(.geoBlocked), .ytdlpFailed(.live), .ytdlpFailed(.rateLimited), .toolsChanged:
                return report(tried)
            case .needsSignIn where !refusals.blocked:
                return report(.needsSignIn)
            default:
                break
            }
        }
        if found.isEmpty, refusals.blocked {
            guard play != nil else { return report(.blocked) }
            return await playAndRead(page, report: report)
        }
        if found.isEmpty, refusals.any { return report(.needsSignIn) }
        if found.isEmpty, play != nil { return await playAndRead(page, report: report) }
        guard play != nil, !refusals.blocked, !page.hasDataFromDowlioConnect, isThin(found, readerFound: steps.readerFound, on: page) else { return report(.found(found)) }
        let left = longestLooking - (ContinuousClock.now - start)
        guard left > .seconds(1) else { return report(.found(found)) }
        report(.checkingForMore(found))
        guard let more = await lookedAgain(page, within: left) else { return }
        report(.found(Self.added(more.candidates, to: found)))
    }

    private func withYTDLP(_ page: SentPage, opensAsAudio: Bool) async -> PageAnalysis {
        guard let ytdlp else { return .found([]) }
        guard await ytdlp.isInstalled else { return .needsTools }
        let label = page.title ?? Self.site(of: page.url)
        do {
            let info = try await Self.infoRetryingWithSignIn(for: page, from: ytdlp)
            let playlists = await playlists(neededBy: info, on: page)
            let versions = Self.withExtras(
                YTDLPVersions.versions(of: info, page: page.url, decodesAV1: decodesAV1, playlists: playlists),
                video: MediaExtras(subtitles: SubtitleSelection.choose(info, for: subtitles())),
                audio: MediaExtras()
            )
            return .found([Candidate(
                label: info.title ?? label, thumbnail: info.thumbnail, duration: info.duration, versions: versions, opensAsAudio: opensAsAudio
            )])
        } catch ToolInstaller.Failure.changed, is ChildProcess.CouldNotStart {
            return .toolsChanged
        } catch is CancellationError {
            return .found([])
        } catch let failure as YTDLPFailure {
            switch failure {
            case .needsSignIn: return .needsSignIn
            case .protected: return .found([Candidate(label: label, versions: [], restriction: .protected)])
            default: return .ytdlpFailed(failure)
            }
        } catch {
            return .ytdlpFailed(.extractorBroken)
        }
    }

    private func playlists(neededBy info: MediaInfo, on page: SentPage) async -> [String: MediaPlaylist] {
        let needed = info.formats.filter { YTDLPVersions.needsPlaylist($0, among: info.formats) }
        guard !needed.isEmpty else { return [:] }
        let refusals = Refusals()
        return await withTaskGroup(of: (String, MediaPlaylist)?.self) { group in
            for format in needed {
                guard let url = format.url else { continue }
                var options = mediaOptions(page, for: url)
                if let agent = format.headers["User-Agent"] { options.userAgent = agent }
                if let referrer = format.headers["Referer"].flatMap(URL.init(string:)) { options.referrer = referrer }
                if let origin = format.headers["Origin"] { options.origin = origin }
                group.addTask {
                    guard case .media(let playlist) = await self.playlist(at: url, options: options, refusals: refusals),
                          HLSVersions.restriction(of: playlist) == nil, !playlist.fragments.isEmpty else { return nil }
                    return (format.id, playlist)
                }
            }
            var found: [String: MediaPlaylist] = [:]
            for await pair in group { if let pair { found[pair.0] = pair.1 } }
            return found
        }
    }

    static let mostEmbedsRead = 3

    private static func withExtras(_ versions: [Version], video: MediaExtras, audio: MediaExtras) -> [Version] {
        versions.map { version in
            guard case .media(let media) = version.source else { return version }
            var withExtras = version
            withExtras.source = .media(media.with(extras: media.isAudio ? audio : video))
            return withExtras
        }
    }

    private static func isOffered(_ candidate: Candidate) -> Bool {
        !candidate.versions.isEmpty || candidate.restriction != nil
    }

    private func youTubeEmbeds(in reading: HTMLReader?, on page: SentPage, within limit: Duration) async -> PageAnalysis {
        guard ytdlp != nil, page.framedBy == nil, let reading, limit > .zero else { return .found([]) }
        var seen = Set<URL>()
        let embeds = Array(reading.frames.map(\.url).filter { YouTubeLink($0) != nil && seen.insert($0).inserted }.prefix(Self.mostEmbedsRead))
        guard !embeds.isEmpty else { return .found([]) }
        let results = await withTaskGroup(of: (Int, PageAnalysis)?.self) { group in
            for (index, url) in embeds.enumerated() {
                group.addTask {
                    let framed = SentPage(url: url, userAgent: page.userAgent, framedBy: page.url)
                    return (index, await self.withYTDLP(framed, opensAsAudio: false))
                }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            var found: [Int: PageAnalysis] = [:]
            while found.count < embeds.count, let next = await group.next() {
                guard let (index, analysis) = next else { break }
                found[index] = analysis
            }
            group.cancelAll()
            return embeds.indices.compactMap { found[$0] }
        }
        if results.contains(.needsTools) { return .needsTools }
        return .found(results.flatMap { result -> [Candidate] in
            guard case .found(let candidates) = result else { return [] }
            return candidates.filter(Self.isOffered)
        })
    }

    private static func infoRetryingWithSignIn(for page: SentPage, from ytdlp: YTDLPRunner) async throws -> MediaInfo {
        do {
            return try await ytdlp.infoUpdatingIfBroken(for: page.url, cookies: [])
        } catch let failure as YTDLPFailure where (failure == .needsSignIn || failure == .private) && !page.cookies.isEmpty {
            return try await ytdlp.infoUpdatingIfBroken(for: page.url, cookies: page.cookies)
        }
    }

    static let mostFramesRead = 3

    private func frameCandidates(on page: SentPage, reading: HTMLReader?, within limit: Duration) async -> [Candidate] {
        guard page.framedBy == nil, !page.hasDataFromDowlioConnect, let reading else { return [] }
        let picked = Array(reading.playerFrames(recognisedBy: readers).prefix(Self.mostFramesRead))
        guard !picked.isEmpty else { return [] }
        let parentLabel = Self.label(of: page, reading: reading)
        return await withTaskGroup(of: (Int, [Candidate])?.self) { group in
            for (index, frame) in picked.enumerated() {
                group.addTask {
                    let framed = SentPage(url: frame.url, userAgent: page.userAgent, framedBy: page.url)
                    return (index, await self.quickCandidates(on: framed, labelledAs: parentLabel))
                }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            var found: [Int: [Candidate]] = [:]
            while found.count < picked.count, let next = await group.next() {
                guard let (index, candidates) = next else { break }
                found[index] = candidates
            }
            group.cancelAll()
            return picked.indices.flatMap { found[$0] ?? [] }
        }
    }

    private struct QuickSteps {
        var found: [Candidate]
        var readerFound: Bool
    }

    private func quickSteps(on page: SentPage, reading: HTMLReader?, refusals: Refusals, report: (PageAnalysis) -> Void) async -> QuickSteps {
        async let fromSite = readSite(page, reading: reading, refusals: refusals)
        let fromPage = await candidates(on: page, reading: reading, refusals: refusals, report: report)
        let site = await fromSite
        return QuickSteps(found: Self.joined(fromPage, site, on: page), readerFound: site != nil)
    }

    private func quickCandidates(on page: SentPage, labelledAs fallback: String) async -> [Candidate] {
        let refusals = Refusals()
        let reading = await read(page, refusals: refusals)
        let steps = await quickSteps(on: page, reading: reading, refusals: refusals) { _ in }
        let ownLabel = Self.label(of: page, reading: reading)
        let titled = reading?.title != nil
        return steps.found.map { candidate in
            var labelled = candidate
            if !titled, candidate.label == ownLabel { labelled.label = fallback }
            return labelled
        }
    }

    private func isThin(_ found: [Candidate], readerFound: Bool, on page: SentPage) -> Bool {
        if readers.contains(where: { $0.recognises(page.url) }), !readerFound { return true }
        let videos = found.flatMap(\.versions).filter { !$0.isAudio && !$0.isExtractedAudio }
        let streams = videos.filter { if case .media = $0.source { true } else { false } }
        return streams.isEmpty && videos.count <= 1
    }

    private static func added(_ more: [Candidate], to shown: [Candidate]) -> [Candidate] {
        var rows = shown.map(\.withoutExtractedAudio)
        var rest: [Candidate] = []
        for candidate in more.map(\.withoutExtractedAudio) {
            let urls = Set(candidate.versions.map(\.source.url))
            if let index = rows.firstIndex(where: { !Set($0.versions.map(\.source.url)).isDisjoint(with: urls) }) {
                rows[index] = rows[index].joining(candidate)
            } else {
                rest.append(candidate)
            }
        }
        if rows.count == 1, rest.count == 1, rest[0].restriction == nil, rows[0].restriction == nil,
           rows[0].duration == nil || rest[0].duration == nil || sameLength(rows[0].duration, rest[0].duration) {
            rows[0] = rows[0].joining(rest[0])
            rest = []
        }
        return merged(rows + rest).map { $0.withExtractedAudio(splittable: []) }
    }

    private func linkedPlaylist(_ page: SentPage, label: String) async -> PageAnalysis {
        let refusals = Refusals()
        let candidates = await sized(await streamCandidates([page.url], page: page, refusals: refusals, label: label, thumbnail: nil, fragments: StreamFragments()), on: page)
        return candidates.isEmpty && refusals.any ? .needsSignIn : .found(candidates.map { $0.withExtractedAudio(splittable: []) })
    }

    public func probe(_ candidate: Candidate, on sent: SentPage) async -> Candidate {
        await Self.within(sent) { await probeWithin(candidate, on: sent) }
    }

    private func probeWithin(_ candidate: Candidate, on sent: SentPage) async -> Candidate {
        let (page, agent) = identified(sent)
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
        return found.requested(by: agent)
    }

    private struct PageContext: Sendable {
        var page: SentPage
        var reading: HTMLReader?
        var label: String
        var shown: Set<URL>
        var watchedFiles: Set<URL>
        var scriptedFiles: Set<URL> = []
        var fragments = StreamFragments()
    }

    private func candidates(on page: SentPage, reading: HTMLReader?, refusals: Refusals, report: (PageAnalysis) -> Void) async -> [Candidate] {
        var players = Players()
        for media in page.scan { players.add(media, from: "page") }
        let readMedia = reading?.media ?? []
        for media in readMedia where !DASHVersions.isStream(media.url) { players.add(media, from: "html") }
        let scripted = readers.contains(where: { $0.recognises(page.url) }) ? [] : reading?.scriptMedia ?? []
        var streams = page.watched
            .filter { $0.kind == .manifest || DASHVersions.isStream($0.url, contentType: $0.contentType) }
            .map(\.url)
        for url in readMedia.map(\.url) + scripted where DASHVersions.isStream(url) && !streams.contains(url) { streams.append(url) }
        let shown = Set(players.list.flatMap(\.sources).map(\.url))
        let scriptedFiles = scripted.filter { !DASHVersions.isStream($0) && !shown.contains($0) }
        let watchedFiles = Set(page.watched.filter { $0.kind == .file }.map(\.url) + scriptedFiles).subtracting(shown)
        for request in page.watched where request.kind == .file && !StreamFragments.isNamedLikeAFragment(request.url, nextTo: streams) {
            let kind = MediaFile.kind(of: request.url, contentType: request.contentType) ?? .video
            if let group = PageLayout.matchingPlayer(for: request.url, in: page.players) {
                players.add(ScannedMedia(url: request.url, kind: kind, group: group), from: "page")
            } else {
                players.add(ScannedMedia(url: request.url, kind: kind), from: "watched")
            }
        }
        for url in scriptedFiles { players.add(ScannedMedia(url: url, kind: MediaFile.kind(of: url) ?? .video), from: "watched") }
        let layout = PageLayout(page: page, players: players.list.map { ($0.group, $0.sources) }, streams: streams)
        let label = Self.label(of: page, reading: reading)
        let fragments = StreamFragments()
        let context = PageContext(
            page: page, reading: reading, label: label, shown: shown, watchedFiles: watchedFiles, scriptedFiles: Set(scriptedFiles), fragments: fragments
        )
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
        var fromPlayers = false
    }

    private func readSite(_ page: SentPage, reading: HTMLReader?, refusals: Refusals) async -> SiteFinding? {
        let chosen: [any SiteReader]
        if let reader = readers.first(where: { $0.recognises(page.url) }) {
            chosen = [reader]
        } else if let html = reading?.html {
            chosen = readers.filter { $0.recognisesPlayer(in: html) }
        } else {
            chosen = []
        }
        guard !chosen.isEmpty else { return nil }
        let site = page.url.host(percentEncoded: false) ?? page.url.absoluteString
        let sitePage = SitePage(
            url: page.url, embeddedJSON: page.embeddedJSON + (reading?.embeddedJSON ?? []), html: reading?.html, cookies: page.cookies,
            framedBy: page.framedBy, send: { url, body, headers in try await self.readerData(at: url, for: page, sending: body, headers: headers) }
        ) { url in
            try await self.readerData(at: url, for: page)
        }
        let fallback = Self.label(of: page, reading: reading)
        var found: [Candidate] = []
        for reader in chosen {
            let videos: [SiteVideo]
            do {
                videos = try await reader.read(sitePage)
            } catch {
                readerFailed(ReaderFailure(reader: reader.name, site: site, reason: String(describing: error)))
                continue
            }
            var fromReader: [Candidate] = []
            for video in videos {
                let label = video.label ?? Self.player(lasting: video.duration, on: page)?.label ?? fallback
                fromReader += await candidates(of: video, on: page, label: label, refusals: refusals)
            }
            if fromReader.isEmpty { readerFailed(ReaderFailure(reader: reader.name, site: site, reason: "found nothing")) }
            found += fromReader
        }
        guard !found.isEmpty else { return nil }
        let isPost = chosen.count == 1 && chosen[0].post(in: page.url) != nil
        return SiteFinding(
            candidates: await sized(found, on: page).map { $0.withExtractedAudio(splittable: []) }, isPost: isPost,
            fromPlayers: !chosen.contains { $0.recognises(page.url) }
        )
    }

    private func sized(_ candidates: [Candidate], on page: SentPage) async -> [Candidate] {
        await sizes.sized(candidates) { url, version in
            var options = mediaOptions(page, for: url)
            if let referrer = version.referrer { options.referrer = referrer }
            if let origin = version.origin { options.origin = origin }
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
        let streamed = await streamCandidates(
            video.streams, page: page, refusals: refusals, label: label, thumbnail: video.thumbnail, fragments: StreamFragments(), rules: video.rules
        )
        let found = video.versions + streamed.flatMap(\.versions)
        let versions = Self.distinct(video.rules.map { rules in found.map(rules.applied(to:)) } ?? found)
        guard !versions.isEmpty else { return streamed.filter { $0.restriction != nil } }
        return [Candidate(
            label: label, thumbnail: video.thumbnail ?? streamed.lazy.compactMap(\.thumbnail).first,
            duration: video.duration ?? streamed.compactMap(\.duration).max(), versions: versions
        )]
    }

    private func readerData(at url: URL, for page: SentPage, sending body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        var options = mediaOptions(page, for: url)
        if let parent = page.framedBy { options.referrer = parent }
        guard Self.mayReach(url) else { throw SiteReaderError.unreadable }
        var request = request(for: url, options: options)
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
        }
        await cooldown.wait(for: request)
        guard let (data, http) = try await limitedData(for: request) else { throw SiteReaderError.unreadable }
        await noteReply(http, for: request)
        guard (200..<300).contains(http.statusCode) else { throw SiteReaderError.refused(status: http.statusCode) }
        return data
    }

    private static func joined(_ fromPage: [Candidate], _ fromSite: SiteFinding?, on page: SentPage) -> [Candidate] {
        guard let fromSite else { return fromPage }
        if fromSite.isPost { return fromSite.candidates }
        if fromSite.fromPlayers { return replacing(fromPage, with: fromSite.candidates) }
        var rows = fromPage
        let players = PageLayout.ordered(page.players)
        var taken = Set<Int>()
        var placed: [(rank: Int, candidate: Candidate)] = []
        for candidate in fromSite.candidates {
            let ids = candidate.addressIDs
            let shared = rows.firstIndex { !$0.addresses.isDisjoint(with: candidate.addresses) }
                ?? (ids.isEmpty ? nil : rows.firstIndex { !$0.addressIDs.isDisjoint(with: ids) })
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

    private static func replacing(_ rows: [Candidate], with players: [Candidate]) -> [Candidate] {
        var rows = rows
        var placed: [Candidate] = []
        for player in players {
            let overlapping = rows.indices.filter { !rows[$0].addresses.isDisjoint(with: player.addresses) }
            guard let first = overlapping.first else {
                placed.append(player)
                continue
            }
            var joined = overlapping.reduce(player) { $0.joining(rows[$1]) }
            joined.isOnScreen = overlapping.contains { rows[$0].isOnScreen }
            for index in overlapping.reversed() where index != first { rows.remove(at: index) }
            rows[first] = joined
        }
        return rows + placed
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
            place.shown.contains(version.source.url)
                || !(Self.looksLikeAnAd(version, on: place.page.url) || Self.isShortScriptedFile(version, in: place))
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
        _ urls: [URL], page: SentPage, refusals: Refusals, label: String, thumbnail: URL?, fragments: StreamFragments, rules: RequestRules? = nil
    ) async -> [Candidate] {
        var parsed: [(URL, Playlist)] = []
        var candidates: [Candidate] = []
        var seen = Set<URL>()
        func options(for url: URL) -> RequestOptions {
            let options = mediaOptions(page, for: url)
            return rules?.applied(to: options) ?? options
        }
        for url in urls where seen.insert(url).inserted {
            guard let (data, http) = await fetch(request(for: url, options: options(for: url)), refusals: refusals) else { continue }
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
            let options = options(for: url)
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
        if let origin = options.origin ?? url.crossOrigin(from: options.referrer) { request.setValue(origin, forHTTPHeaderField: "Origin") }
        identify(&request)
        if !options.cookies.isEmpty {
            request.setValue(options.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func identify(_ request: inout URLRequest) {
        if let languages = identity.acceptLanguage { request.setValue(languages, forHTTPHeaderField: "Accept-Language") }
    }

    private func fetch(_ request: URLRequest, refusals: Refusals) async -> (Data, HTTPURLResponse)? {
        var request = request
        request.httpShouldHandleCookies = false
        guard let url = request.url, Self.mayReach(url) else { return nil }
        await cooldown.wait(for: request)
        guard let found = try? await limitedData(for: request) else { return nil }
        let (data, http) = found
        refusals.note(status: http.statusCode)
        await noteReply(http, for: request)
        if LinkInspection.isWebPage(mimeType: http.value(forHTTPHeaderField: "Content-Type")), BlockedPage.isChallenge(String(decoding: data.prefix(BlockedPage.largestHead), as: UTF8.self)) {
            refusals.noteBlocked()
        }
        guard (200..<300).contains(http.statusCode), data.count <= Self.largestPage else { return nil }
        return (data, http)
    }

    private func limitedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse)? {
        try await LimitedRead(limit: Self.largestPage, reachesLocalNetwork: Self.reachesLocalNetwork).read(request, in: session)
    }

    private func noteReply(_ reply: HTTPURLResponse, for request: URLRequest) async {
        guard reply.statusCode == 429 else { return }
        await cooldown.cool(HostCooldown.host(of: request), for: BlockedPage.wait(from: reply.value(forHTTPHeaderField: "Retry-After")))
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

    private static func isShortScriptedFile(_ version: Version, in place: PageContext) -> Bool {
        guard place.scriptedFiles.contains(version.source.url), let size = version.totalBytes else { return false }
        return size < smallestWatchedFileFromAnotherSite
    }

    private static func looksLikeAnAd(_ version: Version, on page: URL) -> Bool {
        if AdSites.hosts(version.source.url) { return true }
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
        let fetchSite = page.framedBy.map { Self.site(of: $0) == Self.site(of: page.url) ? "same-site" : "cross-site" } ?? "none"
        for (name, value) in ["Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": page.framedBy == nil ? "document" : "iframe", "Sec-Fetch-Site": fetchSite] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let parent = page.framedBy { request.setValue(parent.absoluteString, forHTTPHeaderField: "Referer") }
        if let agent = page.userAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        identify(&request)
        let cookies = page.cookies.sent(to: page.url, from: page.url)
        if !cookies.isEmpty {
            request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        guard let (data, http) = await fetch(request, refusals: refusals),
              LinkInspection.isWebPage(mimeType: http.value(forHTTPHeaderField: "Content-Type")) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        return HTMLReader(html, base: http.url ?? page.url)
    }

    private func pageOptions(_ page: SentPage) -> RequestOptions {
        var options = RequestOptions()
        options.cookies = page.cookies.sent(to: page.url, from: page.url)
        options.userAgent = page.userAgent
        return options
    }

    private func mediaOptions(_ page: SentPage, for url: URL) -> RequestOptions {
        var options = pageOptions(page)
        options.cookies = page.cookies.sent(to: url, from: page.url)
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

private extension PageAnalysis {
    func requested(by agent: String?) -> PageAnalysis {
        guard let agent else { return self }
        switch self {
        case .found(let candidates): return .found(candidates.map { $0.requested(by: agent) })
        case .looking(let candidates): return .looking(candidates.map { $0.requested(by: agent) })
        case .checkingForMore(let candidates): return .checkingForMore(candidates.map { $0.requested(by: agent) })
        case .playing, .needsSignIn, .blocked, .plainFile, .needsTools, .toolsChanged, .ytdlpFailed: return self
        }
    }
}

private extension SentPage {
    var hasDataFromDowlioConnect: Bool {
        throughDowlioConnect && !(scan.isEmpty && watched.isEmpty)
    }
}

private extension Candidate {
    var withoutExtractedAudio: Candidate {
        var stripped = self
        stripped.versions.removeAll(where: \.isExtractedAudio)
        return stripped
    }

    func joining(_ other: Candidate) -> Candidate {
        var joined = self
        joined.versions = PageAnalyzer.distinct(versions.filter { !$0.isExtractedAudio } + other.versions)
        joined.thumbnail = thumbnail ?? other.thumbnail
        joined.duration = duration ?? other.duration
        joined.unprobed = []
        return joined
    }

    var addresses: Set<URL> {
        Set(versions.filter { !$0.isExtractedAudio }.map(\.source.url))
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
            version.userAgent = version.userAgent ?? agent
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
    private var isBlocked = false

    var any: Bool { lock.withLock { refused } }
    var blocked: Bool { lock.withLock { isBlocked } }

    func note(_ error: any Error) {
        guard let error = error as? DownloadError, error == .needsSignIn || error == .forbidden else { return }
        lock.withLock { refused = true }
    }

    func note(status: Int) {
        if status == 429 { noteBlocked() }
        guard status == 401 || status == 403 else { return }
        lock.withLock { refused = true }
    }

    func noteBlocked() {
        lock.withLock { isBlocked = true }
    }
}

final class LimitedRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let reachesLocalNetwork: Bool
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var isTooLarge = false
    private var answer: CheckedContinuation<(Data, HTTPURLResponse)?, Error>?

    init(limit: Int, reachesLocalNetwork: Bool) {
        self.limit = limit
        self.reachesLocalNetwork = reachesLocalNetwork
    }

    func read(_ request: URLRequest, in session: URLSession) async throws -> (Data, HTTPURLResponse)? {
        let task = session.dataTask(with: request)
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { answer = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.expectedContentLength <= Int64(limit) else {
            lock.withLock { isTooLarge = true }
            return completionHandler(.cancel)
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let overLimit = lock.withLock {
            data.append(chunk)
            isTooLarge = data.count > limit
            return isTooLarge
        }
        if overLimit { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard reachesLocalNetwork || !LocalAddress.isLocal(request.url) else { return completionHandler(nil) }
        var request = request
        if !Self.sameOrigin(response.url ?? task.currentRequest?.url, request.url) {
            for name in ["Cookie", "Authorization", "Origin"] { request.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<(Data, HTTPURLResponse)?, Error>?, Result<(Data, HTTPURLResponse)?, Error>) in
            defer { answer = nil }
            if isTooLarge { return (answer, .success(nil)) }
            if let error { return (answer, .failure(error)) }
            return (answer, .success(response.map { (data, $0) }))
        }
        continuation?.resume(with: result)
    }

    static func sameOrigin(_ one: URL?, _ other: URL?) -> Bool {
        guard let one, let other, let host = one.host()?.lowercased(), let scheme = one.scheme?.lowercased() else { return false }
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil) }
        return scheme == other.scheme?.lowercased() && host == other.host()?.lowercased() && port(one) == port(other)
    }
}

public enum LocalAddress {
    public static func isLocal(_ url: URL?) -> Bool {
        guard let host = url?.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }
        var parts = host.split(separator: ".").compactMap { UInt8($0) }
        if let whole = host.hasPrefix("0x") ? UInt32(host.dropFirst(2), radix: 16) : UInt32(host) {
            parts = [UInt8(whole >> 24), UInt8(whole >> 16 & 0xff), UInt8(whole >> 8 & 0xff), UInt8(whole & 0xff)]
        }
        if parts.count == 4, !host.contains(":") {
            switch (parts[0], parts[1]) {
            case (127, _), (10, _), (0, _), (169, 254), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if host.contains(":") {
            return host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") || host.hasPrefix("::ffff:")
        }
        return false
    }
}
