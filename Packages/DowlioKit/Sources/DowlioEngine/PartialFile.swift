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

    /// Reserves `bytes` on disk for the data file, so a download that can't fit fails before it
    /// starts (architecture.md, files on disk). Throws `DownloadError.notEnoughSpace` if the volume
    /// can't hold it.
    func reserve(bytes: Int64) throws {
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATEALL),
            fst_posmode: Int32(F_PEOFPOSMODE),
            fst_offset: 0,
            fst_length: off_t(bytes),
            fst_bytesalloc: 0
        )
        guard fcntl(handle.fileDescriptor, F_PREALLOCATE, &store) != -1 else {
            let code = errno
            if code == ENOSPC { throw DownloadError.notEnoughSpace }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
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

/// Where a download's partial file is, shared between the download and the engine, so the engine
/// can delete it on Cancel. `nil` before the partial file exists and after the file is finished.
final class PartialFileLocation: @unchecked Sendable {
    // @unchecked: `stored` is only read or written under `lock`.
    private let lock = NSLock()
    private var stored: URL?

    var url: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
