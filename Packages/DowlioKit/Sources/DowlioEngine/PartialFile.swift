import DowlioCore
import Foundation

/// The `.dowlio` package that holds an unfinished download, next to its destination.
final class PartialFile: @unchecked Sendable {
    // @unchecked: one download writes to it from one task at a time.

    static let fileExtension = "dowlio"

    let packageURL: URL
    private let dataURL: URL
    private let handle: FileHandle
    private var isClosed = false

    private init(packageURL: URL, dataURL: URL, handle: FileHandle) {
        self.packageURL = packageURL
        self.dataURL = dataURL
        self.handle = handle
    }

    deinit {
        if !isClosed { try? handle.close() }
    }

    /// Creates a new package for `fileName` in `folder`. If `name.ext.dowlio` exists, it tries
    /// `name.ext 2.dowlio`, `name.ext 3.dowlio` and so on. It never reuses an existing package.
    static func create(for fileName: String, in folder: URL) throws -> PartialFile {
        var number = 1
        while true {
            let base = number == 1 ? fileName : "\(fileName) \(number)"
            let package = folder.appending(path: "\(base).\(fileExtension)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
                return try open(package)
            } catch CocoaError.fileWriteFileExists {
                number += 1
            } catch {
                throw DownloadError.destinationNotWritable
            }
        }
    }

    /// Opens the data file inside a new package, or removes the package if that fails.
    private static func open(_ package: URL) throws -> PartialFile {
        let dataURL = package.appending(path: "data")
        guard FileManager.default.createFile(atPath: dataURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dataURL) else {
            try? FileManager.default.removeItem(at: package)
            throw DownloadError.destinationNotWritable
        }
        return PartialFile(packageURL: package, dataURL: dataURL, handle: handle)
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    private let writeLock = NSLock()

    /// Writes `data` at `offset` in the data file. Segments call this from several connections,
    /// and the lock makes it the one serial writer the spec asks for.
    func write(_ data: Data, at offset: Int64) throws {
        try writeLock.withLock {
            try data.withUnsafeBytes { buffer in
                var done = 0
                while done < buffer.count {
                    let written = pwrite(
                        handle.fileDescriptor,
                        buffer.baseAddress! + done,
                        buffer.count - done,
                        off_t(offset) + off_t(done)
                    )
                    guard written > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    done += written
                }
            }
        }
    }

    /// Flushes the data, moves it to `destination` in one atomic rename and deletes the package.
    /// Throws `DownloadError.fileExists`, and leaves the package in place, if `destination` exists.
    func finish(as destination: URL) throws {
        try handle.synchronize()
        try handle.close()
        isClosed = true
        // RENAME_EXCL makes the rename fail instead of replacing an existing file, atomically.
        guard renamex_np(dataURL.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw DownloadError.fileExists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try FileManager.default.removeItem(at: packageURL)
    }
}
