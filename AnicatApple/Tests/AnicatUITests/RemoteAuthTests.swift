import CryptoKit
import Foundation
import Testing
@testable import AnicatUI

@Suite("Remote pairing and framing")
struct RemoteAuthTests {
    @Test("Both ends of a key exchange derive the same pairing secret")
    func bothEndsAgree() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let onPhone = RemoteAuth.secret(mine: phone, theirs: RemoteAuth.publicKey(of: mac))
        let onMac = RemoteAuth.secret(mine: mac, theirs: RemoteAuth.publicKey(of: phone))
        #expect(onPhone != nil)
        #expect(onPhone == onMac)

        // Someone who saw both public keys and made one of their own gets a
        // different secret.
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        #expect(RemoteAuth.secret(mine: stranger, theirs: RemoteAuth.publicKey(of: mac)) != onMac)
        #expect(RemoteAuth.secret(mine: phone, theirs: "not a key") == nil)
    }

    @Test("A proof holds only for its secret, role and every part")
    func proofsAreBound() throws {
        let secret = try #require(RemoteAuth.secret(
            mine: Curve25519.KeyAgreement.PrivateKey(),
            theirs: RemoteAuth.publicKey(of: Curve25519.KeyAgreement.PrivateKey())
        ))
        let other = try #require(RemoteAuth.secret(
            mine: Curve25519.KeyAgreement.PrivateKey(),
            theirs: RemoteAuth.publicKey(of: Curve25519.KeyAgreement.PrivateKey())
        ))
        let proof = try #require(RemoteAuth.proof(.phone, secret: secret, ["a", "b"]))

        #expect(RemoteAuth.verify(proof, role: .phone, secret: secret, ["a", "b"]))
        #expect(!RemoteAuth.verify(proof, role: .phone, secret: other, ["a", "b"]))
        // The Mac's proof must not be accepted as the phone's.
        #expect(!RemoteAuth.verify(proof, role: .mac, secret: secret, ["a", "b"]))
        #expect(!RemoteAuth.verify(proof, role: .phone, secret: secret, ["b", "a"]))
        #expect(!RemoteAuth.verify(proof, role: .phone, secret: secret, ["a", "b", "c"]))
        #expect(!RemoteAuth.verify(nil, role: .phone, secret: secret, ["a", "b"]))
        #expect(!RemoteAuth.verify("", role: .phone, secret: secret, ["a", "b"]))
        #expect(!RemoteAuth.verify("!!", role: .phone, secret: secret, ["a", "b"]))
    }

    @Test("Moving a boundary between parts changes the proof")
    func partsAreLengthPrefixed() throws {
        let secret = Data(repeating: 7, count: 32).base64EncodedString()
        let one = try #require(RemoteAuth.proof(.dataRequest, secret: secret, ["ab", "c"]))
        let two = try #require(RemoteAuth.proof(.dataRequest, secret: secret, ["a", "bc"]))
        #expect(one != two)
    }

    @Test("Nonces are never repeated")
    func noncesDiffer() {
        #expect(RemoteAuth.nonce() != RemoteAuth.nonce())
    }

    @Test("A hello from before the handshake decodes with no nonce or key")
    func oldHelloDecodes() throws {
        let old = Data(#"{"hello":{"deviceId":"a","deviceName":"b"}}"#.utf8)
        guard case .hello(let id, _, let nonce, let key) = try JSONDecoder().decode(RemoteFrame.self, from: old) else {
            Issue.record("not a hello")
            return
        }
        #expect(id == "a")
        #expect(nonce == nil)
        #expect(key == nil)
    }

    @Test("An unauthenticated peer cannot grow the buffer without end")
    func framerCutsOffAnUnterminatedFlood() {
        var framer = RemoteFramer()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 8 * 1024)
        _ = framer.ingest(chunk)
        #expect(!framer.overflowed)
        _ = framer.ingest(chunk)
        _ = framer.ingest(chunk)
        #expect(framer.overflowed)
    }

    @Test("A read that carries whole frames is not measured as an unterminated one")
    func framerMeasuresOnlyTheTail() throws {
        var framer = RemoteFramer()
        let hello = RemoteFrame.hello(deviceId: "d", deviceName: "n", nonce: nil, authKey: nil)
        let line = try #require(RemoteFramer.encode(hello))
        var burst = Data()
        for _ in 0..<(RemoteFramer.unauthenticatedLimit / line.count + 50) { burst.append(line) }
        #expect(burst.count > RemoteFramer.unauthenticatedLimit)
        let frames = framer.ingest(burst)
        #expect(frames.count > 50)
        #expect(!framer.overflowed)
    }

    @Test("An authenticated connection takes a frame the size of the sync table")
    func framerAllowsALargeFrameOnceTrusted() throws {
        let rows = (0..<2000).map {
            SyncRelease(
                catalog: "anilist",
                catalogId: Int64($0),
                episodeNumber: 1,
                name: String(repeating: "n", count: 100),
                magnet: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40),
                torrentUrl: nil,
                assumeBatch: false,
                preferDub: false,
                resolvedAt: "2026-10-12 12:00:00"
            )
        }
        let line = try #require(RemoteFramer.encode(.syncOffer(rows)))
        #expect(line.count > RemoteFramer.unauthenticatedLimit)

        var strict = RemoteFramer()
        _ = strict.ingest(line.dropLast())
        #expect(strict.overflowed)

        var trusted = RemoteFramer(limit: RemoteFramer.authenticatedLimit)
        #expect(trusted.ingest(line).count == 1)
        #expect(!trusted.overflowed)
    }
}
