import CryptoKit
import Foundation

/// What lets a Mac and a phone know each other on a network anyone can join.
///
/// The remote used to recognise a phone by its `deviceId`, a UUID the phone
/// sends in clear on every connection, so one sniffed hello was a standing
/// pass to drive the Mac, ask it to resolve and download titles, and write
/// into its remembered releases. Now pairing agrees a secret that never
/// crosses the wire (an X25519 exchange, kept only if the person at the Mac
/// taps Allow), and every later connection and byte range proves it holds
/// that secret with an HMAC over fresh values. Both ends prove it: a Mac
/// that merely advertises the right Bonjour name gets nothing.
///
/// This authenticates, it does not encrypt. Someone able to sit inside an
/// established TCP connection can still read it or take it over; closing
/// that needs TLS on the link and is a larger change.
enum RemoteAuth {
    /// 256 bits, base64: a connection nonce, never reused.
    static func nonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// The secret both ends compute from their own private key and the
    /// other's public one. The salt binds it to this protocol and the info
    /// to this pair of keys, so the same key pair means nothing elsewhere.
    static func secret(
        mine: Curve25519.KeyAgreement.PrivateKey,
        theirs: String
    ) -> String? {
        guard let raw = Data(base64Encoded: theirs),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        // Sorted so the phone and the Mac, which each know "mine" and
        // "theirs" the other way round, feed the KDF the same bytes.
        let keys = [mine.publicKey.rawRepresentation, raw].sorted { $0.lexicographicallyPrecedes($1) }
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("anicat-remote-pairing-v1".utf8),
            sharedInfo: keys[0] + keys[1],
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    static func publicKey(of key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Who is vouching, folded into the message so a proof the Mac made
    /// cannot be handed back to it as the phone's.
    enum Role: String {
        case mac = "anicat-mac"
        case phone = "anicat-phone"
    }

    static func proof(_ role: Role, secret: String, _ parts: [String]) -> String? {
        guard let key = symmetricKey(secret) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: message(role, parts), using: key)
        return Data(mac).base64EncodedString()
    }

    /// Constant time: `==` on the strings would leak how much of a guess
    /// matched.
    static func verify(_ proof: String?, role: Role, secret: String, _ parts: [String]) -> Bool {
        guard let proof, let code = Data(base64Encoded: proof), let key = symmetricKey(secret) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: message(role, parts), using: key)
    }

    private static func symmetricKey(_ secret: String) -> SymmetricKey? {
        Data(base64Encoded: secret).map { SymmetricKey(data: $0) }
    }

    /// Length-prefixed, not joined with a separator: a title or token with
    /// the separator in it must not be able to move a boundary and make two
    /// different messages hash alike.
    private static func message(_ role: Role, _ parts: [String]) -> Data {
        var data = Data()
        for part in [role.rawValue] + parts {
            let bytes = Data(part.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }
}
