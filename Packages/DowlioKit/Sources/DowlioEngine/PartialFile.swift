import CoreServices
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

    /// Flushes the data file to disk, then writes `manifest` atomically. The caller takes the
    /// manifest's counts before calling, so the saved counts never lead the bytes on disk.
    func saveManifest(_ manifest: PartialFileManifest) throws {
        guard !isClosed else { return }
        try handle.synchronize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: packageURL.appending(path: "manifest.json"), options: .atomic)
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    /// Empties the data file, so a download from a server that can't resume starts over.
    func discardData() throws {
        try handle.truncate(atOffset: 0)
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

    /// What `finish` did with the data file.
    struct Finished: Equatable {
        /// The name the finished file got. With the skip policy, the download's own planned name.
        let name: String
        /// The skip policy kept an existing file with that name, so the new file was thrown away.
        let wasSkipped: Bool
    }

    /// Flushes the data, moves it into `folder` as `fileName` in one atomic rename, deletes the
    /// package and returns the name the finished file got. If `fileName` is taken, `policy` decides.
    func finish(named fileName: String, in folder: URL, policy: NameConflictPolicy, source: URL) throws -> Finished {
        try handle.synchronize()
        try handle.close()
        isClosed = true
        try markAsDownloaded(from: source)

        if policy == .replace {
            // A plain rename replaces an existing file atomically.
            guard rename(dataURL.path, folder.appending(path: fileName).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try FileManager.default.removeItem(at: packageURL)
            return Finished(name: fileName, wasSkipped: false)
        }

        var number = 1
        while true {
            let name = number == 1 ? fileName : Self.numbered(fileName, number)
            // RENAME_EXCL makes the rename fail instead of replacing an existing file, atomically.
            if renamex_np(dataURL.path, folder.appending(path: name).path, UInt32(RENAME_EXCL)) == 0 {
                try FileManager.default.removeItem(at: packageURL)
                return Finished(name: name, wasSkipped: false)
            }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            if policy == .skip {
                try FileManager.default.removeItem(at: packageURL)
                return Finished(name: fileName, wasSkipped: true)
            }
            number += 1
        }
    }

    /// Sets the quarantine attribute a browser sets on its downloads, with Dowlio as the agent, so
    /// macOS checks a downloaded app or disk image before it first opens. It's set before the
    /// rename, so the finished file never exists without it.
    private func markAsDownloaded(from source: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Dowlio",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: source,
        ]
        var url = dataURL
        try url.setResourceValues(values)
    }

    /// Reads the manifest of the package at `package`. Throws `RestoreError.unreadableManifest`
    /// when it's missing or isn't a manifest this version understands.
    static func readManifest(in package: URL) throws -> PartialFileManifest {
        guard let data = try? Data(contentsOf: package.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(PartialFileManifest.self, from: data),
              (PartialFileManifest.oldestReadableFormatVersion...PartialFileManifest.currentFormatVersion)
                  .contains(manifest.formatVersion) else {
            throw RestoreError.unreadableManifest
        }
        return manifest
    }

    /// Opens the data file of an existing package for writing, keeping its bytes.
    static func openExisting(_ package: URL) throws -> PartialFile {
        let dataURL = package.appending(path: "data")
        guard let handle = try? FileHandle(forUpdating: dataURL) else { throw RestoreError.unreadableManifest }
        return PartialFile(packageURL: package, dataURL: dataURL, handle: handle)
    }

    /// Whether the package's data file is gone from disk, for example deleted in Finder.
    var isMissing: Bool {
        !FileManager.default.fileExists(atPath: dataURL.path)
    }

    /// "name 2.ext" for "name.ext", or "name 2" for a name without an extension.
    private static func numbered(_ fileName: String, _ number: Int) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
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
