import DowlioCore
import Foundation

extension DownloadEngine {
    /// Asks the server about `url` the way a download's probe does, with one try and no download.
    /// Throws `DownloadError`.
    public nonisolated func inspect(_ url: URL, options: RequestOptions = RequestOptions()) async throws -> LinkInspection {
        let connections = ConnectionOpener(
            originalURL: url, options: options, idleTimeout: configuration.idleTimeout,
            sessions: configuration.sessions, now: configuration.now
        )
        let probed: Probed
        do {
            probed = try await ServerProbe(connections: connections).probe(url)
        } catch let error as DownloadError {
            throw error
        } catch is RetryableFailure {
            throw DownloadError.network(NetworkFailure(
                code: .badServerResponse, message: "The server is busy or failing."
            ))
        } catch {
            throw DownloadError.network(NetworkFailure(error))
        }
        probed.cancelConnection()

        let response = probed.probeResponse
        let fileName = FileNaming.name(for: response, finalURL: probed.finalURL)
        let contentType = response.contentTypeHeader
        let splits: Bool
        let cannotResume: CannotResumeReason?
        switch probed.body {
        case .whole:
            splits = false
            cannotResume = probed.totalBytes == nil ? .sizeUnknown : .noRangeSupport
        case .ranges(_, let validator):
            splits = true
            cannotResume = validator == nil ? .noValidator : nil
        }
        return LinkInspection(
            fileName: fileName,
            totalBytes: probed.totalBytes,
            contentType: contentType,
            category: Category(fileName: fileName, contentType: contentType),
            splitsIntoSegments: splits,
            cannotResumeBecause: cannotResume,
            isNotSecure: url.isPlainHTTP || probed.finalURL.isPlainHTTP
        )
    }
}
