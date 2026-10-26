import CommonCrypto
import DowlioCore
import Foundation

final class FragmentKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var fetches: [URL: Task<Data, any Error>] = [:]

    func key(at url: URL, fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let fetching = lock.withLock {
            if let existing = fetches[url] { return existing }
            let started = Task { try await fetch() }
            fetches[url] = started
            return started
        }
        do {
            return try await fetching.value
        } catch {
            lock.withLock { if fetches[url] == fetching { fetches[url] = nil } }
            throw error
        }
    }
}

enum FragmentDecryption {
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { throw DownloadError.mediaUnplayable }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                            out.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DownloadError.mediaUnplayable }
        return output.prefix(moved)
    }
}

extension DownloadRun {
    func decrypt(_ file: URL, with key: FragmentKey, of plan: MediaPlan) async throws -> Int64 {
        let secret = try await plan.keys.key(at: key.url) { [connections] in
            let connection = connections.open(key.url, range: nil)
            defer { connection.cancel() }
            let response = try await connection.firstResponse()
            guard (200..<300).contains(response.statusCode) else { throw connections.failure(for: response) }
            var received = Data()
            for try await event in connection.events {
                if case .data(let data) = event { received.append(data) }
            }
            return received
        }
        let plain = try FragmentDecryption.decrypt(try Data(contentsOf: file), key: secret, iv: key.iv)
        try plain.write(to: file)
        return Int64(plain.count)
    }
}
