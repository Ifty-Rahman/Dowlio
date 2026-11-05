import CryptoKit
import Foundation

public final class FakeGitHub: @unchecked Sendable {
    public let server: TestServer

    public init() async throws {
        server = try await TestServer()
    }

    public var api: URL { server.url(for: "") }

    public static var quickJSAsset: String {
        #if arch(arm64)
        "qjs-darwin-arm64"
        #else
        "qjs-darwin-x86_64"
        #endif
    }

    public struct Asset {
        public var name: String
        public var data: Data
        public var digest: String?

        public init(name: String, data: Data, digest: String? = nil) {
            self.name = name
            self.data = data
            self.digest = digest
        }
    }

    public func publish(
        repository: String, version: String, assets: [Asset], prerelease: Bool = false, redirectingDownloadsTo redirect: URL? = nil
    ) {
        let listed = assets.map { asset -> [String: Any] in
            let path = "/\(repository)/releases/download/\(version)/\(asset.name)"
            server.serve(TestServer.File(data: asset.data), at: path)
            if let redirect {
                let moved = "/moved\(path)"
                server.redirect(moved, to: redirect.appending(path: path).absoluteString)
                return ["name": asset.name, "size": asset.data.count, "browser_download_url": server.url(for: moved).absoluteString,
                        "digest": asset.digest ?? Self.digest(asset.data)]
            }
            return ["name": asset.name, "size": asset.data.count, "browser_download_url": server.url(for: path).absoluteString,
                    "digest": asset.digest ?? Self.digest(asset.data)]
        }
        let release: [String: Any] = ["tag_name": version, "name": version, "prerelease": prerelease, "draft": false, "assets": listed]
        let json = try! JSONSerialization.data(withJSONObject: release)
        server.serve(TestServer.File(data: json, headers: ["Content-Type": "application/json"]), at: "/repos/\(repository)/releases/latest")
    }

    public func publishYTDLP(version: String, zip: Data, sums: String? = nil, prerelease: Bool = false, redirectingDownloadsTo redirect: URL? = nil) {
        let hash = Self.hex(zip)
        let listed = sums ?? "\(Self.hex(Data("other".utf8)))  yt-dlp_linux\n\(hash)  yt-dlp_macos.zip\n"
        publish(
            repository: "yt-dlp/yt-dlp", version: version,
            assets: [Asset(name: "yt-dlp_macos.zip", data: zip), Asset(name: "SHA2-256SUMS", data: Data(listed.utf8))],
            prerelease: prerelease, redirectingDownloadsTo: redirect
        )
    }

    public func publishQuickJS(version: String, binary: Data, digest: String? = nil) {
        publish(repository: "quickjs-ng/quickjs", version: version, assets: [Asset(name: Self.quickJSAsset, data: binary, digest: digest)])
    }

    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> String { "sha256:\(hex(data))" }

    public static func standInYTDLP(script: String) throws -> Data {
        let folder = try TestFiles.makeFolder().appending(path: "yt-dlp", directoryHint: .isDirectory)
        let internals = folder.appending(path: "_internal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: internals, withIntermediateDirectories: true)
        try Data("library".utf8).write(to: internals.appending(path: "base_library.zip"))
        let executable = folder.appending(path: "yt-dlp_macos")
        try "#!/bin/sh\n\(script)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let zip = folder.deletingLastPathComponent().appending(path: "yt-dlp_macos.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", folder.path, zip.path]
        try process.runUntilExit()
        return try Data(contentsOf: zip)
    }

    public static func standInQuickJS() -> Data {
        Data("#!/bin/sh\nexit 0\n".utf8)
    }
}
