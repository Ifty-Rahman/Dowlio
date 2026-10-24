import Foundation

/// What a link gives before it's downloaded, as the New Download sheet's file card shows it.
public struct LinkInspection: Equatable, Sendable {
    public var fileName: String
    /// `nil` while the server doesn't say.
    public var totalBytes: Int64?
    /// The `Content-Type` without its parameters, lowercased.
    public var contentType: String?
    public var category: Category?
    /// The server answers byte ranges, so the download uses several connections.
    public var splitsIntoSegments: Bool
    /// Why pausing would start the file over, or `nil` when the download can resume.
    public var cannotResumeBecause: CannotResumeReason?
    /// The link or its redirects use plain HTTP (ADR 0003).
    public var isNotSecure: Bool

    public init(
        fileName: String,
        totalBytes: Int64?,
        contentType: String?,
        category: Category?,
        splitsIntoSegments: Bool,
        cannotResumeBecause: CannotResumeReason?,
        isNotSecure: Bool
    ) {
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.contentType = contentType
        self.category = category
        self.splitsIntoSegments = splitsIntoSegments
        self.cannotResumeBecause = cannotResumeBecause
        self.isNotSecure = isNotSecure
    }
}

public enum CannotResumeReason: Equatable, Sendable {
    /// The server sends the whole file for every request.
    case noRangeSupport
    /// The server doesn't say how big the file is.
    case sizeUnknown
    /// The server sends no strong `ETag` or `Last-Modified`, so a resume can't tell whether the
    /// file changed.
    case noValidator
}
