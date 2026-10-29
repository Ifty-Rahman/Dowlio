import DowlioCore
import DowlioEngine
import DowlioMedia
import Foundation

enum SiteCheck {
    static let pagesAtOnce = 4

    enum Result: String {
        case found = "found"
        case nothingFound = "nothing found"
        case needsSignIn = "needs sign-in"
        case plainFile = "plain file"
        case failed = "error"
    }

    struct Outcome: Sendable {
        var url: URL
        var seconds: Double
        var analysis: PageAnalysis
        var error: String?

        var candidates: [Candidate] {
            if case .found(let candidates) = analysis { return candidates }
            return []
        }

        var result: Result {
            switch analysis {
            case .found(let candidates) where !candidates.isEmpty: .found
            case .needsSignIn: .needsSignIn
            case .plainFile: .plainFile
            case .found, .looking, .checkingForMore, .playing: error == nil ? .nothingFound : .failed
            }
        }

        var foundSomething: Bool { result == .found || result == .plainFile }

        var needsLookAgain: Bool { result == .nothingFound }
    }

    static func run(_ arguments: [String]) async {
        var rest = arguments[...]
        var asJSON = false
        var agent: String?
        var paths: [String] = []
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": asJSON = true
            case "--user-agent":
                guard let value = rest.popFirst() else { fail(usage) }
                agent = value
            default: paths.append(argument)
            }
        }
        guard paths.count == 1 else { fail(usage) }
        let text: String
        do {
            text = try String(contentsOfFile: paths[0], encoding: .utf8)
        } catch {
            fail("Can't read \(paths[0]).")
        }
        let outcomes = await analyze(links(in: text), identity: BrowserIdentity(userAgent: agent))
        print(asJSON ? json(outcomes) : report(outcomes))
    }

    static func links(in text: String) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            guard let url = URL(string: trimmed), url.scheme != nil else { fail("Not a link: \(trimmed)") }
            return url
        }
    }

    static func analyze(_ links: [URL], identity: BrowserIdentity) async -> [Outcome] {
        let engine = DownloadEngine(identity: { identity })
        return await withTaskGroup(of: (Int, Outcome).self) { group in
            var found: [Int: Outcome] = [:]
            for (index, url) in links.enumerated() {
                if index >= pagesAtOnce, let (done, outcome) = await group.next() { found[done] = outcome }
                group.addTask { (index, await analyze(url, engine: engine, identity: identity)) }
            }
            for await (done, outcome) in group { found[done] = outcome }
            return links.indices.compactMap { found[$0] }
        }
    }

    private static func analyze(_ url: URL, engine: DownloadEngine, identity: BrowserIdentity) async -> Outcome {
        let pageError = PageError()
        let analyzer = PageAnalyzer(identity: identity, readerFailed: { _ in }) { inspected, options in
            do {
                return try await engine.inspect(inspected, options: options)
            } catch {
                if inspected == url { pageError.note(error) }
                throw error
            }
        }
        let start = ContinuousClock.now
        var last = PageAnalysis.found([])
        for await update in analyzer.analyze(SentPage(url: url)) { last = update }
        let took = ContinuousClock.now - start
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        return Outcome(url: url, seconds: seconds, analysis: last, error: pageError.message)
    }

    static func report(_ outcomes: [Outcome]) -> String {
        var lines: [String] = []
        for outcome in outcomes {
            lines.append(outcome.url.absoluteString)
            lines.append(String(format: "  took %.1f s", outcome.seconds))
            switch outcome.result {
            case .found:
                break
            case .nothingFound:
                lines.append("  nothing found, would need Look Again")
            case .failed:
                lines.append("  error: " + (outcome.error ?? "unknown"))
            case .needsSignIn, .plainFile:
                lines.append("  " + outcome.result.rawValue)
            }
            for candidate in outcome.candidates {
                var heading = "  " + candidate.label
                if let duration = candidate.duration { heading += " · \(Int(duration.rounded())) s" }
                if let restriction = candidate.restriction { heading += " · " + name(of: restriction) }
                lines.append(heading)
                lines += candidate.versions.map { "    " + describe($0) }
            }
            lines.append("")
        }
        lines.append("Found something on \(outcomes.filter(\.foundSomething).count) of \(outcomes.count) links")
        return lines.joined(separator: "\n")
    }

    private static func name(of restriction: Candidate.Restriction) -> String {
        switch restriction {
        case .protected: "protected"
        case .live: "live"
        case .needsPassword: "needs password"
        }
    }

    private static func kind(of version: Version) -> String {
        switch version.source {
        case .file: "file"
        case .media(let media): media.extractsAudio ? "extracted audio" : "stream"
        }
    }

    private static func describe(_ version: Version) -> String {
        var parts = [kind(of: version)]
        parts.append(version.isAudio ? "audio" : version.height.map { "\($0)p" } ?? "no resolution")
        if let codecs = version.codecs { parts.append(codecs) }
        if let language = version.language { parts.append(language) }
        parts.append(version.totalBytes.map { (version.isEstimatedSize ? "~" : "") + bytes($0) } ?? "size unknown")
        return parts.joined(separator: ", ")
    }

    private static func bytes(_ count: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return (formatter.string(from: NSNumber(value: count)) ?? "\(count)") + " bytes"
    }

    static func json(_ outcomes: [Outcome]) -> String {
        let links: [[String: Any]] = outcomes.map { outcome in
            [
                "url": outcome.url.absoluteString,
                "seconds": (outcome.seconds * 10).rounded() / 10,
                "result": outcome.result.rawValue,
                "error": orNull(outcome.error),
                "needsLookAgain": outcome.needsLookAgain,
                "candidates": outcome.candidates.map { candidate -> [String: Any] in
                    [
                        "label": candidate.label,
                        "duration": orNull(candidate.duration),
                        "restriction": orNull(candidate.restriction.map(name(of:))),
                        "versions": candidate.versions.map { version -> [String: Any] in
                            [
                                "kind": kind(of: version),
                                "audio": version.isAudio,
                                "resolution": orNull(version.height),
                                "codecs": orNull(version.codecs),
                                "language": orNull(version.language),
                                "bytes": orNull(version.totalBytes),
                                "estimated": version.isEstimatedSize,
                            ]
                        },
                    ]
                },
            ]
        }
        let report: [String: Any] = ["links": links, "found": outcomes.filter(\.foundSomething).count, "total": outcomes.count]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }
}

private final class PageError: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?

    var message: String? { lock.withLock { first } }

    func note(_ error: any Error) {
        let text = (error as? DownloadError).map(describe) ?? error.localizedDescription
        lock.withLock { if first == nil { first = text } }
    }

    private func describe(_ error: DownloadError) -> String {
        if case .network(let failure) = error { return failure.message }
        return "\(error)"
    }
}
