import Foundation
import CryptoKit
import Security

/// Crypto helpers that the BLE layer leans on:
///  - a persistent X25519 identity key stored in iOS Keychain
///    (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
///  - safety-code derivation (Signal-style) for a pair of identity
///    public keys
///  - replay-counter encoded inside the AEAD payload
enum Crypto {

    // MARK: identity key

    private static let kcService = "recode.letychka32.identityKey"
    private static let kcAccount = "v1"

    /// Long-lived X25519 keypair, generated once and kept in Keychain.
    /// Used ONLY for identity binding (safety code, future signatures).
    /// All actual session encryption still uses per-connection
    /// ephemeral keys, so leaking this key never decrypts past
    /// traffic.
    static let identityKey: Curve25519.KeyAgreement.PrivateKey = {
        if let raw = readKeychain(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(
               rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        writeKeychain(key.rawRepresentation)
        return key
    }()

    static var identityPub: Data { identityKey.publicKey.rawRepresentation }

    private static func readKeychain() -> Data? {
        var q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     kcService,
            kSecAttrAccount as String:     kcAccount,
            kSecMatchLimit as String:      kSecMatchLimitOne,
            kSecReturnData as String:      true
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
    private static func writeKeychain(_ data: Data) {
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     kcService,
            kSecAttrAccount as String:     kcAccount,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    // MARK: safety code

    /// Signal-style safety number for a pair of identity public keys.
    /// Both sides compute the same string because the inputs are
    /// sorted before hashing. Format: three groups of 4 hex chars
    /// (12 chars = 48 bits, enough to detect MITM by voice compare).
    static func safetyCode(myID: Data, theirID: Data) -> String {
        let (a, b) = myID.lexicographicallyPrecedes(theirID)
            ? (myID, theirID) : (theirID, myID)
        let h = SHA256.hash(data: a + b)
        let hex = h.map { String(format: "%02X", $0) }.joined()
        let trimmed = String(hex.prefix(12))
        // 4-4-4 grouping
        let s = trimmed
        let g1 = s.prefix(4)
        let g2 = s.dropFirst(4).prefix(4)
        let g3 = s.dropFirst(8).prefix(4)
        return "\(g1) \(g2) \(g3)"
    }

    // MARK: replay-counter helpers

    /// 8-byte big-endian counter prepended to the inner encrypted
    /// frame so the receiver can drop replayed AEAD payloads even
    /// when they pass the AES-GCM authentication tag.
    static func counterBytes(_ n: UInt64) -> Data {
        withUnsafeBytes(of: n.bigEndian) { Data($0) }
    }
    static func readCounter(_ d: Data) -> UInt64? {
        guard d.count >= 8 else { return nil }
        let bytes = Array(d.prefix(8))
        var v: UInt64 = 0
        for b in bytes { v = (v << 8) | UInt64(b) }
        return v
    }
}
