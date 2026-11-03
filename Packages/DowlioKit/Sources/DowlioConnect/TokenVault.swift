import CryptoKit
import Foundation
import Security

public protocol TokenVault: Sendable {
    func save(hash: Data, for pairing: UUID) throws
    func pairing(for hash: Data) throws -> UUID?
    func hashes() throws -> [Data]
    func remove(pairing: UUID) throws
}

enum PairingToken {
    static func make() -> String {
        ConnectProof.random(bytes: 32)
    }

    static func hash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }
}

enum ConnectProof {
    static func key(_ secret: Data) -> String {
        code(secret, "dowlio-connect key")
    }

    static func server(_ secret: Data, client: String, server: String) -> String {
        code(secret, "dowlio-connect server \(client) \(server)")
    }

    static func client(_ secret: Data, client: String, server: String) -> String {
        code(secret, "dowlio-connect client \(client) \(server)")
    }

    static func isClient(_ proof: String, _ secret: Data, client: String, server: String) -> Bool {
        guard let raw = Data(base64URL: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            raw, authenticating: Data("dowlio-connect client \(client) \(server)".utf8), using: SymmetricKey(data: secret)
        )
    }

    static func pairingCode() -> String {
        var number: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &number) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return String(format: "%06u", number % 1_000_000)
    }

    static func random(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    private static func code(_ secret: Data, _ text: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: secret))).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
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

    public func hashes() throws -> [Data] {
        storedHashes
    }

    public func remove(pairing: UUID) throws {
        lock.withLock { pairings = pairings.filter { $0.value != pairing } }
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

    public func hashes() throws -> [Data] {
        try items().compactMap { item in
            (item[kSecAttrAccount as String] as? String).flatMap(Self.hash(fromHex:))
        }
    }

    public func remove(pairing: UUID) throws {
        for hash in try hashes() where try self.pairing(for: hash) == pairing {
            let status = SecItemDelete(baseQuery(for: hash) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
        }
    }

    private func items() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return result as? [[String: Any]] ?? []
    }

    private static func hash(fromHex text: String) -> Data? {
        guard text.count == 64 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
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
