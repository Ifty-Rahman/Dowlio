import DowlioCore
import DowlioMedia
import Foundation

public struct SentPageDraft: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case looking
        case playing
        case found
        case nothingFound
        case needsSignIn
        case blocked
        case restricted(Candidate.Restriction)
        case needsTools
        case installingTools
        case declinedTools
        case couldntInstallTools
        case toolsChanged

        public var isAboutTools: Bool {
            [.needsTools, .installingTools, .declinedTools, .couldntInstallTools, .toolsChanged].contains(self)
        }
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
    public let preference: QualityPreference
    public private(set) var phase = Phase.looking
    public private(set) var candidates: [Candidate] = []
    public private(set) var selected = 0
    public private(set) var isCheckingForMore = false
    public private(set) var toolsSize: Int64?
    private var included: Set<Int> = []
    private var picks: [Int: Version] = [:]
    private var showings: [Int: Showing] = [:]

    public var showing: Showing { showings[selected] ?? .video }
    private var play: PlayRun?

    private enum PlayRun {
        case byItself
        case asked
    }

    public init(page: SentPage, preference: QualityPreference = QualityPreference()) {
        self.page = page
        self.preference = preference
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
        case .checkingForMore(let found):
            show(found)
            isCheckingForMore = true
            return nil
        case .playing:
            phase = .playing
            if play == nil { play = .byItself }
            return nil
        case .needsSignIn:
            candidates = []
            phase = .needsSignIn
            return nil
        case .blocked:
            candidates = []
            phase = .blocked
            return nil
        case .plainFile(let url):
            return url
        case .needsTools:
            candidates = []
            phase = .needsTools
            return nil
        case .toolsChanged:
            candidates = []
            phase = .toolsChanged
            return nil
        case .found(let found):
            show(found)
            return nil
        }
    }

    private mutating func show(_ found: [Candidate]) {
        let refreshing = isCheckingForMore
        isCheckingForMore = false
        let previous = candidates
        let previousSelected = selected
        let previousIncluded = included
        let previousPicks = picks
        let previousShowings = showings
        candidates = found
        selected = 0
        included = []
        picks = [:]
        showings = [:]
        phase = Self.phase(of: found)
        guard refreshing else { return }
        func moved(_ index: Int) -> Int? {
            let urls = Set(previous[index].versions.map(\.source.url))
            return found.firstIndex { !Set($0.versions.map(\.source.url)).isDisjoint(with: urls) }
        }
        if previous.indices.contains(previousSelected), let index = moved(previousSelected) { selected = index }
        included = Set(previousIncluded.compactMap(moved))
        for (index, version) in previousPicks {
            if let to = moved(index), found[to].versions.contains(version) { picks[to] = version }
        }
        for (index, showing) in previousShowings {
            if let to = moved(index) { showings[to] = showing }
        }
    }

    public mutating func stopChecking() {
        isCheckingForMore = false
    }

    public var checkingLine: String { "Checking for more versions" }

    public mutating func setToolsSize(_ size: Int64?) {
        toolsSize = size
    }

    public mutating func startInstallingTools() {
        phase = .installingTools
    }

    public mutating func declineTools() {
        phase = .declinedTools
    }

    public mutating func askForToolsAgain() {
        guard phase == .declinedTools || phase == .couldntInstallTools else { return }
        phase = .needsTools
    }

    public mutating func failInstallingTools() {
        phase = .couldntInstallTools
    }

    public var toolConsent: ToolConsentText {
        let size = toolsSize.map { " About \(max(Int((Double($0) / 1_000_000).rounded()), 1)) MB." } ?? ""
        return ToolConsentText(
            title: "Download yt-dlp and QuickJS-NG?",
            explanation: "This site needs yt-dlp, a free open-source tool, and QuickJS-NG, which yt-dlp uses for YouTube. "
                + "Dowlio downloads them from their GitHub pages." + size,
            tools: Tool.allCases.map { ToolConsentText.Link(name: $0.name, project: $0.project) },
            keepsUpToDate: true,
            agree: "Download",
            decline: "Not Now"
        )
    }

    public var installingLine: String { "Downloading yt-dlp and QuickJS-NG" }
    public var declinedLine: String { "Dowlio needs yt-dlp to read this page. Nothing was downloaded." }
    public var couldntInstallLine: String {
        "Dowlio couldn't download yt-dlp and QuickJS-NG from GitHub. Check your connection and try again."
    }
    public var toolsChangedLine: String {
        "yt-dlp or QuickJS-NG changed since Dowlio installed it, so Dowlio won't run it. Reinstall it to read this page."
    }

    private static func phase(of found: [Candidate]) -> Phase {
        guard !found.isEmpty else { return .nothingFound }
        let restrictions = Set(found.map(\.restriction))
        guard restrictions.count == 1, let only = restrictions.first, let restriction = only else { return .found }
        return restriction == .needsPassword ? .needsSignIn : .restricted(restriction)
    }

    public var restrictionLine: String? {
        switch selectedCandidate?.restriction {
        case .protected: "This video is protected and can't be downloaded"
        case .live: "Live stream, not supported yet"
        case .needsPassword: Self.passwordLine
        case nil: nil
        }
    }

    public mutating func lookAgain() {
        play = .asked
        phase = .playing
    }

    public mutating func cancelPlaying() {
        guard phase == .playing else { return }
        phase = .nothingFound
        play = nil
    }

    static let passwordLine = "This video needs a password. Open it in your browser, enter the password, then send the page."

    public var signIn: [String] {
        if !candidates.isEmpty, candidates.allSatisfy({ $0.restriction == .needsPassword }) { return [Self.passwordLine] }
        let next = "This site only shows this video to signed-in visitors. Sign in to it in your browser, then send the page again."
        return page.throughDowlioConnect ? [next] : [next, "Install Dowlio Connect so Dowlio can use your sign-in."]
    }

    public var blocked: [String] {
        let first = "\(host) wants to check you're a person. Open the page in your browser, then send it to Dowlio."
        return page.throughDowlioConnect ? [first] : [first, "Install Dowlio Connect so Dowlio can use your sign-in."]
    }

    public var lookingLine: String {
        phase == .playing ? "Playing the page to find the video" : "Looking at the page"
    }

    public var nothingFound: NothingFoundText {
        NothingFoundText(
            title: "No video or audio found on this page",
            explanation: "Dowlio couldn't find any audio or video to download on this page.",
            action: play == nil ? "Look Again" : "Try Again"
        )
    }

    public var selectedCandidate: Candidate? {
        candidates.indices.contains(selected) ? candidates[selected] : nil
    }

    public mutating func replace(_ waiting: Candidate, with found: Candidate) {
        guard let index = candidates.firstIndex(of: waiting) else { return }
        candidates[index] = found
        picks[index] = nil
    }

    public mutating func select(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        selected = index
    }

    public func chosenVersion(of index: Int) -> Version? {
        guard candidates.indices.contains(index) else { return nil }
        let versions = candidates[index].versions
        guard !versions.isEmpty else { return nil }
        let showing = showings[index] ?? .video
        if let pick = picks[index], versions.contains(pick), MediaText.isAudio(pick) == (showing == .audio) { return pick }
        if !versions.contains(where: MediaText.isAudio) || !versions.contains(where: { !MediaText.isAudio($0) }) {
            return preference.pick(from: versions, showing: MediaText.isAudio(versions[0]) ? .audio : .video) ?? versions.first
        }
        return preference.pick(from: versions, showing: showing)
    }

    public mutating func show(_ kind: Showing) {
        showings[selected] = kind
    }

    public mutating func moveChoice(by step: Int) {
        let rows = hasVideoAndAudio ? versions(showing: showing) : selectedCandidate?.versions ?? []
        guard !rows.isEmpty, let current = chosenVersion, let index = rows.firstIndex(of: current) else { return }
        picks[selected] = rows[min(max(index + step, 0), rows.count - 1)]
    }

    public var chosenVersion: Version? { chosenVersion(of: selected) }

    public mutating func pick(_ version: Version) {
        picks[selected] = version
        if hasVideoAndAudio { showings[selected] = MediaText.isAudio(version) ? .audio : .video }
    }

    public func isIncluded(_ index: Int) -> Bool { included.contains(index) }

    public mutating func include(_ index: Int, _ included: Bool) {
        if included { self.included.insert(index) } else { self.included.remove(index) }
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
}

public struct NothingFoundText: Equatable, Sendable {
    public var title: String
    public var explanation: String
    public var action: String

    public init(title: String, explanation: String, action: String) {
        self.title = title
        self.explanation = explanation
        self.action = action
    }
}

public enum MediaText {
    public static func isAudio(_ version: Version) -> Bool {
        version.isAudio
    }

    public static func isH264(_ version: Version) -> Bool {
        let codecs = version.codecs?.lowercased() ?? ""
        return codecs.contains("h.264") || codecs.contains("h264") || codecs.contains("avc")
    }

    public static func isMP4(_ version: Version) -> Bool {
        ["mp4", "m4v"].contains(version.source.url.pathExtension.lowercased()) || version.contentType?.lowercased() == "video/mp4"
    }

    public static func container(of version: Version) -> String {
        if case .media(let media) = version.source { return media.outputContainer.displayName }
        let ext = version.source.url.pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return version.contentType?.split(separator: "/").last.map { $0.uppercased() } ?? "File"
    }

    public static func title(of version: Version) -> String {
        if isAudio(version) { return "Audio" }
        if let height = version.height { return "\(height)p" }
        return container(of: version)
    }

    public static func detail(of version: Version) -> String {
        let parts = isAudio(version)
            ? [container(of: version), version.codecs, version.language, version.isExtractedAudio ? "extracted after download" : nil]
            : [version.height == nil ? nil : container(of: version), version.codecs]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private static let extensionsByType: [String: String] = [
        "video/mp4": "mp4", "video/x-m4v": "m4v", "video/webm": "webm", "video/quicktime": "mov", "video/x-matroska": "mkv",
        "video/mpeg": "mpg", "video/ogg": "ogv", "video/3gpp": "3gp", "video/x-flv": "flv", "video/mp2t": "ts",
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/ogg": "ogg",
        "audio/opus": "opus", "audio/wav": "wav", "audio/x-wav": "wav", "audio/flac": "flac", "audio/webm": "weba",
    ]

    private static let mediaExtensions = Set(extensionsByType.values).union(["oga", "mpeg"])

    public static func fileExtension(of version: Version) -> String {
        if case .media(let media) = version.source { return media.fileExtension }
        let named = version.source.url.pathExtension
        guard !mediaExtensions.contains(named.lowercased()) else { return named }
        let type = version.contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return type.flatMap { extensionsByType[$0] } ?? named
    }

    public static func size(of version: Version) -> String? {
        version.totalBytes.map { (version.isEstimatedSize ? "~" : "") + ByteText.string($0) }
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

public struct ToolConsentText: Equatable, Sendable {
    public struct Link: Equatable, Sendable {
        public var name: String
        public var project: URL
    }

    public var title: String
    public var explanation: String
    public var tools: [Link]
    public var keepsUpToDate: Bool
    public var agree: String
    public var decline: String
}
