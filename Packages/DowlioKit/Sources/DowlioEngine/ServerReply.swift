import DowlioCore
import Foundation

extension HTTPURLResponse {
    /// The `Content-Type` header without its parameters, lowercased. Unlike `mimeType`, never a
    /// type the URL loading system guessed.
    var contentTypeHeader: String? {
        value(forHTTPHeaderField: "Content-Type")
            .flatMap { $0.split(separator: ";").first }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    var knownLength: Int64? {
        expectedContentLength >= 0 ? expectedContentLength : nil
    }

    var isUsableRangeReply: Bool {
        let encoding = value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased()
        let type = value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let plain = encoding == nil || encoding == "identity"
        return plain && !type.hasPrefix("multipart/byteranges")
    }

    /// A weak ETag can't be used with `If-Range` (RFC 9110), so it falls back to `Last-Modified`.
    var validator: String? {
        if let tag = value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/") {
            return tag
        }
        return value(forHTTPHeaderField: "Last-Modified")
    }

    func failure(now: Date) -> Error {
        switch statusCode {
        case 401: DownloadError.needsSignIn
        case 403: DownloadError.forbidden
        case 404, 410: DownloadError.notFound
        case 408, 429, 500...599:
            RetryableFailure(
                retryAfter: RetryAfter.parse(value(forHTTPHeaderField: "Retry-After"), now: now),
                isRefusal: statusCode == 429 || statusCode == 503
            )
        default:
            DownloadError.network(NetworkFailure(
                code: .badServerResponse, message: "The server answered with status \(statusCode)."
            ))
        }
    }
}

struct FileChangedOnServer: Error {}

struct RangesUnusable: Error {}
