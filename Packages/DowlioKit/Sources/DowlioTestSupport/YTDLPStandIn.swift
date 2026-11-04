import DowlioMedia
import Foundation

public struct YTDLPStandIn: Sendable {
    public let installer: ToolInstaller
    public let github: FakeGitHub
    public let log: URL

    public static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: "YTDLP/\(name)", withExtension: nil)!
    }

    public static func errorText(_ name: String) -> URL {
        fixture("errors/\(name).txt")
    }

    public static func printing(_ fixture: String) async throws -> YTDLPStandIn {
        try await install(script: "cat '\(Self.fixture(fixture).path)'")
    }

    public static func failing(with error: String) async throws -> YTDLPStandIn {
        try await install(script: "cat '\(errorText(error).path)' >&2\nexit 1")
    }

    private static func body(_ script: String, log: URL) -> String {
        """
            printf '%s\\n' "$@" > '\(log.path)/arguments'
            env > '\(log.path)/environment'
            echo run >> '\(log.path)/runs'
            echo --run-- >> '\(log.path)/all-arguments'
            printf '%s\n' "$@" >> '\(log.path)/all-arguments'
            \(script)
            """
    }

    public static func install(script: String) async throws -> YTDLPStandIn {
        let log = try TestFiles.makeFolder()
        let github = try await FakeGitHub()
        github.publishYTDLP(version: "2026.10.26", zip: try FakeGitHub.standInYTDLP(script: body(script, log: log)))
        github.publishQuickJS(version: "v0.18.0", binary: FakeGitHub.standInQuickJS())
        let installer = ToolInstaller(folder: log.appending(path: "Tools", directoryHint: .isDirectory), source: .testing(api: github.api))
        try await installer.install()
        return YTDLPStandIn(installer: installer, github: github, log: log)
    }

    public func publishUpdate(version: String = "2026.11.03", script: String) throws {
        github.publishYTDLP(version: version, zip: try FakeGitHub.standInYTDLP(script: Self.body(script, log: log)))
    }

    public static func notInstalled() async throws -> YTDLPStandIn {
        let log = try TestFiles.makeFolder()
        let github = try await FakeGitHub()
        let installer = ToolInstaller(folder: log.appending(path: "Tools", directoryHint: .isDirectory), source: .testing(api: github.api))
        return YTDLPStandIn(installer: installer, github: github, log: log)
    }

    public var arguments: [String] {
        ((try? String(contentsOf: log.appending(path: "arguments"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    public var environment: [String: String] {
        let text = (try? String(contentsOf: log.appending(path: "environment"), encoding: .utf8)) ?? ""
        return Dictionary(text.split(separator: "\n").compactMap { line in
            line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
        }) { first, _ in first }
    }

    public var runs: Int {
        ((try? String(contentsOf: log.appending(path: "runs"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }
}
