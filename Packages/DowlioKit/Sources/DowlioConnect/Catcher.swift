import DowlioCore
import DowlioLibrary
import Foundation

public struct CatchOffer: Equatable, Sendable {
    public var url: URL
    public var finalURL: URL?
    public var referrer: URL?
    public var mimeType: String?
    public var userAgent: String?
    public var browserPath: URL?

    public init(url: URL, finalURL: URL? = nil, referrer: URL? = nil, mimeType: String? = nil, userAgent: String? = nil, browserPath: URL? = nil) {
        self.url = url
        self.finalURL = finalURL
        self.referrer = referrer
        self.mimeType = mimeType
        self.userAgent = userAgent
        self.browserPath = browserPath
    }
}

public enum CatchDeclineReason: String, Sendable {
    case needsSignIn
    case unsupported
    case error
}

public enum CatchDecision: Sendable {
    case accept(fileName: String, totalBytes: Int64?, start: @Sendable () async -> DownloadID)
    case decline(CatchDeclineReason)
}

public struct CaughtDownload: Equatable, Sendable {
    public let id: DownloadID
    public let link: URL
    public let fileName: String
    public let totalBytes: Int64?
    let session: UUID

    public init(id: DownloadID, link: URL, fileName: String, totalBytes: Int64?) {
        self.init(id: id, link: link, fileName: fileName, totalBytes: totalBytes, session: UUID())
    }

    init(id: DownloadID, link: URL, fileName: String, totalBytes: Int64?, session: UUID) {
        self.id = id
        self.link = link
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.session = session
    }
}

public struct Catcher: Sendable {
    private let library: Library
    private let settings: @Sendable () -> DownloadSettings
    private let browserDownloadsFolder: URL

    public init(
        library: Library,
        settings: @escaping @Sendable () -> DownloadSettings,
        browserDownloadsFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
    ) {
        self.library = library
        self.settings = settings
        self.browserDownloadsFolder = browserDownloadsFolder
    }

    public func decide(_ offer: CatchOffer) async -> CatchDecision {
        let settings = settings()
        var options = settings.options(connections: nil)
        options.referrer = offer.referrer
        options.userAgent = offer.userAgent
        let link = offer.finalURL ?? offer.url
        let inspection: LinkInspection
        do {
            inspection = try await library.inspect(link, options: options)
        } catch DownloadError.needsSignIn, DownloadError.forbidden {
            return .decline(.needsSignIn)
        } catch {
            return .decline(.error)
        }
        if inspection.isWebPage, !LinkInspection.isWebPage(mimeType: offer.mimeType) {
            return .decline(.unsupported)
        }
        let destination: Destination
        if let chosen = chosenInSaveDialog(offer.browserPath) {
            destination = .folder(chosen.deletingLastPathComponent())
            options.fileName = chosen.lastPathComponent
        } else {
            destination = settings.destination(in: settings.folder)
        }
        let library = library
        let chosenOptions = options
        return .accept(fileName: options.fileName ?? inspection.fileName, totalBytes: inspection.totalBytes) {
            await library.add(link, destination: destination, options: chosenOptions, startImmediately: true)
        }
    }

    func discard(_ id: DownloadID) async {
        await library.discard(id)
    }

    private func chosenInSaveDialog(_ path: URL?) -> URL? {
        guard let path, path.isFileURL, !path.lastPathComponent.isEmpty else { return nil }
        let folder = path.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let downloads = browserDownloadsFolder.standardizedFileURL.resolvingSymlinksInPath().path
        return folder == downloads ? nil : path
    }
}
