import DowlioLibrary
import Foundation

public struct CatchGrouper: Sendable {
    public static let window: TimeInterval = 2

    private var current: CatchNotice?
    private var firstCatch: Date?

    public init() {}

    public mutating func add(_ download: CaughtDownload, at date: Date) -> CatchNotice {
        if var notice = current, let firstCatch, date.timeIntervalSince(firstCatch) < Self.window {
            notice.downloads.append(download)
            current = notice
            return notice
        }
        let notice = CatchNotice(id: UUID(), downloads: [download])
        current = notice
        firstCatch = date
        return notice
    }
}

public struct CatchNotice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public fileprivate(set) var downloads: [CaughtDownload]

    public var single: CaughtDownload? {
        downloads.count == 1 ? downloads[0] : nil
    }

    public var title: String {
        single == nil ? "\(downloads.count) downloads caught" : "Added to Dowlio"
    }

    public var detail: String {
        guard let single else { return FileNames.sentence(downloads.map(\.fileName)) }
        guard let bytes = single.totalBytes else { return single.fileName }
        return "\(single.fileName) · \(ByteText.string(bytes))"
    }

    public var offersDownloadInBrowser: Bool { single != nil }

    public var showTitle: String {
        single == nil ? "Show in Dowlio" : "Show"
    }
}
