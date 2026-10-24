import CryptoKit
import Foundation
import Security

public protocol TokenVault: Sendable {
    func save(hash: Data, for pairing: UUID) throws
    func pairing(for hash: Data) throws -> UUID?
}

enum PairingToken {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }
}

public final class MemoryTokenVault: TokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var pairings: [Data: UUID] = [:]

    public init() {}

    public var storedHashes: [Data] { lock.withLock { Array(pairings.keys) } }

    public func save(hash: Data, for pairing: UUID) throws {
        lock.withLock { pairings[hash] = pairing }
    }

    public func pairing(for hash: Data) throws -> UUID? {
        lock.withLock { pairings[hash] }
    }
}

public struct KeychainTokenVault: TokenVault {
    public enum Failure: Error {
        case keychain(OSStatus)
    }

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(hash: Data, for pairing: UUID) throws {
        var query = baseQuery(for: hash)
        query[kSecValueData as String] = Data(pairing.uuidString.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public func pairing(for hash: Data) throws -> UUID? {
        var query = baseQuery(for: hash)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return UUID(uuidString: String(decoding: data, as: UTF8.self))
    }

    private func baseQuery(for hash: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hash.map { String(format: "%02x", $0) }.joined(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}
