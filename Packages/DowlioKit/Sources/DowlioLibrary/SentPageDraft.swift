import DowlioCore
import DowlioMedia
import Foundation

public struct SentPageDraft: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case looking
        case playing
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
    public let preference: QualityPreference
    public private(set) var showing = Showing.video
    public private(set) var phase = Phase.looking
    public private(set) var candidates: [Candidate] = []
    public private(set) var selected = 0
    private var excluded: Set<Int> = []
    private var picks: [Int: Version] = [:]
    private var play: PlayRun?
    private var emptyResults = 0

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
        case .playing:
            phase = .playing
            if play == nil { play = .byItself }
            return nil
        case .plainFile(let url):
            return url
        case .found(let found):
            candidates = found
            selected = 0
            excluded = []
            picks = [:]
            showing = .video
            phase = found.isEmpty ? .nothingFound : .found
            if found.isEmpty { emptyResults += 1 }
            return nil
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

    public var lookingLine: String {
        phase == .playing ? "Playing the page to find the video" : "Looking at the page"
    }

    public var nothingFound: NothingFoundText {
        let explanation = switch play {
        case .byItself: "Dowlio played the page in a hidden window by itself, and no video loaded. Try Again plays it once more, for up to 10 seconds."
        case .asked: "Dowlio played the page in a hidden window, and no video loaded. Try Again plays it once more, for up to 10 seconds."
        case nil: "Look Again opens the page in a hidden window for up to 10 seconds to catch its video."
        }
        return NothingFoundText(
            title: "No video or audio found on this page",
            explanation: explanation,
            action: play == nil ? "Look Again" : "Try Again",
            note: emptyResults >= 2 ? "This page may not have a video, or its video is protected." : nil
        )
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
        let versions = candidates[index].versions
        if let pick = picks[index], versions.contains(pick), MediaText.isAudio(pick) == (showing == .audio) { return pick }
        if !versions.contains(where: MediaText.isAudio) || !versions.contains(where: { !MediaText.isAudio($0) }) {
            return preference.pick(from: versions, showing: MediaText.isAudio(versions[0]) ? .audio : .video) ?? versions.first
        }
        return preference.pick(from: versions, showing: showing)
    }

    public mutating func show(_ kind: Showing) {
        showing = kind
    }

    public mutating func moveChoice(by step: Int) {
        let rows = hasVideoAndAudio ? versions(showing: showing) : selectedCandidate?.versions ?? []
        guard !rows.isEmpty, let current = chosenVersion, let index = rows.firstIndex(of: current) else { return }
        picks[selected] = rows[min(max(index + step, 0), rows.count - 1)]
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
}

public struct NothingFoundText: Equatable, Sendable {
    public var title: String
    public var explanation: String
    public var action: String
    public var note: String?

    public init(title: String, explanation: String, action: String, note: String?) {
        self.title = title
        self.explanation = explanation
        self.action = action
        self.note = note
    }
}

public enum MediaText {
    public static func isAudio(_ version: Version) -> Bool {
        MediaFile.kind(of: version.source.url, contentType: version.contentType) == .audio
    }

    public static func isH264(_ version: Version) -> Bool {
        let codecs = version.codecs?.lowercased() ?? ""
        return codecs.contains("h.264") || codecs.contains("h264") || codecs.contains("avc")
    }

    public static func isMP4(_ version: Version) -> Bool {
        ["mp4", "m4v"].contains(version.source.url.pathExtension.lowercased()) || version.contentType?.lowercased() == "video/mp4"
    }

    public static func playsInQuickTime(_ version: Version) -> Bool {
        let codecs = version.codecs?.lowercased() ?? ""
        return !(codecs.contains("vp9") || codecs.contains("vp09") || codecs.contains("av1") || codecs.contains("av01"))
    }

    public static func container(of version: Version) -> String {
        if case .media = version.source { return "MP4" }
        let ext = version.source.url.pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return version.contentType?.split(separator: "/").last.map { $0.uppercased() } ?? "File"
    }

    public static func title(of version: Version) -> String {
        if let height = version.height, !isAudio(version) { return "\(height)p" }
        return container(of: version)
    }

    public static func detail(of version: Version) -> String {
        let parts = [version.height == nil || isAudio(version) ? nil : container(of: version), version.codecs]
        return parts.compactMap { $0 }.joined(separator: " · ")
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
