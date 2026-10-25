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
    public var cookies: [Cookie] = []
    public var browserRequest: BrowserRequest?
    public var browser: String?

    public init(
        url: URL, finalURL: URL? = nil, referrer: URL? = nil, mimeType: String? = nil, userAgent: String? = nil,
        browserPath: URL? = nil, cookies: [Cookie] = [], browserRequest: BrowserRequest? = nil
    ) {
        self.cookies = cookies
        self.browserRequest = browserRequest
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
    case accept(start: @Sendable () async -> DownloadID)
    case decline(CatchDeclineReason)
}

public enum CatchStart: Equatable, Sendable {
    case fetching(DownloadRow)
    case refused(CatchDeclineReason)
    case removed
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
        options.cookies = offer.cookies
        options.browserRequest = offer.browserRequest
        let link = offer.finalURL ?? offer.url
        guard let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .decline(.unsupported) }
        let destination: Destination
        if let chosen = chosenInSaveDialog(offer.browserPath) {
            destination = .folder(chosen.deletingLastPathComponent())
            options.fileName = chosen.lastPathComponent
        } else {
            destination = settings.destination(in: settings.folder)
        }
        let library = library
        let chosenOptions = options
        let origin = DownloadOrigin(kind: .caught, browser: offer.browser)
        return .accept {
            await library.add(link, destination: destination, options: chosenOptions, startImmediately: true, origin: origin)
        }
    }

    public func start(of id: DownloadID, waitingAtMost limit: Duration) async -> CatchStart {
        let library = library
        return await withTaskGroup(of: CatchStart?.self) { group in
            group.addTask {
                for await rows in await library.rows() {
                    guard let row = rows.first(where: { $0.id == id }) else { return .removed }
                    if let start = Self.start(shownBy: row) { return start }
                }
                return .removed
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            for await rows in await library.rows() {
                guard let row = rows.first(where: { $0.id == id }) else { break }
                return .fetching(row)
            }
            return .removed
        }
    }

    private static func start(shownBy row: DownloadRow) -> CatchStart? {
        switch row.state {
        case .failed(let error) where row.receivedBytes == 0:
            return .refused(error == .needsSignIn || error == .forbidden ? .needsSignIn : .error)
        case .completed, .queued, .paused, .failed:
            return .fetching(row)
        case .downloading, .retrying:
            return row.receivedBytes > 0 || row.totalBytes != nil ? .fetching(row) : nil
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
