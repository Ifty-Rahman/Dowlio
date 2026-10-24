import DowlioCore
import DowlioEngine
import Foundation

extension EngineConfiguration {
    /// Fast retries, but an idle timeout long enough that a held reply or a busy machine is never
    /// mistaken for a stalled connection. A test about stalls sets its own.
    package static var fast: EngineConfiguration {
        var configuration = EngineConfiguration()
        configuration.retry.firstDelay = .milliseconds(10)
        configuration.retry.maximumDelay = .milliseconds(40)
        configuration.idleTimeout = .seconds(30)
        return configuration
    }
}

/// Starts a two-segment download of `file`, whose replies hold after `file.holdAfterBytes`, and
/// waits until both segments have their held bytes.
public func startHeld(
    _ server: TestServer,
    file: TestServer.File,
    at path: String,
    start: String? = nil,
    options: RequestOptions = RequestOptions()
) async throws -> (DownloadEngine, DownloadID, URL) {
    server.serve(file, at: path)
    let folder = try TestFiles.makeFolder()
    var options = options
    options.connections = 2
    let engine = DownloadEngine(configuration: .fast)
    let id = await engine.add(url: server.url(for: start ?? path), to: folder, options: options)
    let held = Int64(2 * (file.holdAfterBytes ?? 0))
    _ = try await engine.firstSnapshot(of: id) { $0.receivedBytes == held }
    return (engine, id, folder)
}

extension TestFiles {
    public static func partialFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "dowlio" }
    }

    /// The one partial file in `folder`. Throws when there's none or more than one.
    public static func partialFile(in folder: URL) throws -> URL {
        let packages = partialFiles(in: folder)
        guard packages.count == 1, let package = packages.first else {
            throw EngineTestError.notOnePartialFile(found: packages)
        }
        return package
    }
}
