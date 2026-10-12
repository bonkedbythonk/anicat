import Foundation
import Network
import Testing
@testable import AnicatUI

/// The pairing handshake end to end, over a real loopback socket: the Mac's
/// `RemoteHost` on one side of an `NWListener`, the phone's `RemoteClient` on
/// the other. The unit tests cover the arithmetic; this covers the wiring a
/// phone would otherwise be the only way to exercise.
@Suite("Remote handshake", .serialized)
@MainActor
struct RemoteHandshakeTests {
    @MainActor
    private final class Harness {
        let listener: NWListener
        let node: BonjourDiscovery.DiscoveredNode

        init() async throws {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in RemoteHost.shared.accept(connection) }
            }
            let port: UInt16 = await withCheckedContinuation { continuation in
                let once = Once()
                listener.stateUpdateHandler = { state in
                    guard case .ready = state, once.first() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                }
                listener.start(queue: .main)
            }
            self.listener = listener
            node = BonjourDiscovery.DiscoveredNode(
                id: "handshake-test-mac",
                name: "Test Mac",
                host: "127.0.0.1",
                controlPort: port,
                streamPort: 0
            )
            Self.resetDefaults()
        }

        static func resetDefaults() {
            RemoteHost.shared.unpairAll()
            UserDefaults.standard.removeObject(forKey: RemoteClient.hostSecretsKey)
        }

        func tearDown() {
            RemoteClient.shared.disconnect()
            listener.cancel()
            Self.resetDefaults()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func waitUntil(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Pairs the shared client with the harness's Mac, answering Allow.
    private func pair(_ harness: Harness) async -> Bool {
        RemoteClient.shared.connect(to: harness.node)
        guard await waitUntil({ RemoteHost.shared.pendingPairing != nil }) else { return false }
        RemoteHost.shared.answerPairing(approved: true)
        return await waitUntil { RemoteClient.shared.status == .connected }
    }

    @Test("A first pairing needs the person at the Mac, then both ends hold a secret")
    func firstPairing() async throws {
        let harness = try await Harness()
        defer { harness.tearDown() }

        // A phone that has never paired dials nothing by itself.
        #expect(!RemoteClient.knownHosts().contains(harness.node.id))
        #expect(await pair(harness))
        #expect(RemoteClient.knownHosts().contains(harness.node.id))
        #expect(RemoteClient.secret(for: harness.node.id) != nil)
        #expect(RemoteHost.pairedDevices().contains(RemoteClient.deviceId))
    }

    @Test("A paired phone reconnects without a prompt, by proving the secret")
    func reconnectIsSilent() async throws {
        let harness = try await Harness()
        defer { harness.tearDown() }
        #expect(await pair(harness))

        RemoteClient.shared.disconnect()
        RemoteClient.shared.connect(to: harness.node)
        #expect(await waitUntil { RemoteClient.shared.status == .connected })
        #expect(RemoteHost.shared.pendingPairing == nil)
    }

    @Test("A phone whose secret is wrong is not let in and does not prompt")
    func wrongSecretIsRefused() async throws {
        let harness = try await Harness()
        defer { harness.tearDown() }
        #expect(await pair(harness))
        RemoteClient.shared.disconnect()

        let wrong = Data(repeating: 9, count: 32).base64EncodedString()
        UserDefaults.standard.set([harness.node.id: wrong], forKey: RemoteClient.hostSecretsKey)
        RemoteClient.shared.connect(to: harness.node)

        // The phone checks the Mac's proof first, finds it was not made with
        // the secret it holds, and gives up.
        #expect(await waitUntil { if case .failed = RemoteClient.shared.status { return true } else { return false } })
        #expect(RemoteHost.shared.pendingPairing == nil)
    }

    @Test("Someone repeating a paired deviceId, without the secret, is never approved")
    func spoofedDeviceIdIsNeverApproved() async throws {
        let harness = try await Harness()
        defer { harness.tearDown() }
        #expect(await pair(harness))
        RemoteClient.shared.disconnect()
        let stolen = RemoteClient.deviceId

        // Neither a bare hello nor one with a nonce and a made-up proof.
        for attempt in 0..<2 {
            var frames: [RemoteFrame] = [.hello(
                deviceId: stolen,
                deviceName: "Not the phone",
                nonce: attempt == 0 ? nil : RemoteAuth.nonce(),
                authKey: nil
            )]
            if attempt == 1 { frames.append(.proof(Data(repeating: 1, count: 32).base64EncodedString())) }
            let peer = RawPeer(port: harness.node.controlPort, send: .frames(frames))
            try? await Task.sleep(for: .seconds(1))
            let approved = peer.frames.contains {
                if case .helloAck(let accepted, _, _) = $0 { return accepted }
                return false
            }
            peer.cancel()
            #expect(!approved, "attempt \(attempt)")
        }
        #expect(RemoteHost.shared.pendingPairing == nil)
    }

    @Test("A data connection without the secret's proof is refused")
    func dataConnectionNeedsTheProof() async throws {
        let harness = try await Harness()
        defer { harness.tearDown() }
        #expect(await pair(harness))
        RemoteClient.shared.disconnect()

        let peer = RawPeer(port: harness.node.controlPort, send: .frames([
            .helloData(deviceId: RemoteClient.deviceId, token: "any", start: 0, end: 10, proof: nil),
        ]))
        // Hung up on, with no header: the Mac cancels straight after the
        // `dataError`, so the frame itself may never reach the peer.
        #expect(await waitUntil { peer.closed })
        #expect(!peer.frames.contains { if case .dataHeader = $0 { return true } else { return false } })
        peer.cancel()
    }

    @Test("An unauthenticated peer that never ends a line is cut off")
    func floodIsCutOff() async throws {
        let harness = try await Harness()
        defer { harness.tearDown() }

        let peer = RawPeer(port: harness.node.controlPort, send: .junk(64 * 1024))
        #expect(await waitUntil { peer.closed })
        peer.cancel()
    }

    /// A bare TCP client that speaks the wire format without any of the real
    /// client's checks, so the Mac can be shown things the phone would never
    /// send.
    private final class RawPeer: @unchecked Sendable {
        enum Payload: Sendable {
            case frames([RemoteFrame])
            case junk(Int)
        }

        private let connection: NWConnection
        private let lock = NSLock()
        private var framer = RemoteFramer(limit: RemoteFramer.authenticatedLimit)
        private var received: [RemoteFrame] = []
        private var didClose = false

        var frames: [RemoteFrame] { lock.lock(); defer { lock.unlock() }; return received }
        var closed: Bool { lock.lock(); defer { lock.unlock() }; return didClose }

        init(port: UInt16, send payload: Payload) {
            connection = NWConnection(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                using: .tcp
            )
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    switch payload {
                    case .frames(let frames):
                        for frame in frames { self.connection.sendFrame(frame) }
                    case .junk(let count):
                        self.connection.send(
                            content: Data(repeating: UInt8(ascii: "x"), count: count),
                            completion: .idempotent
                        )
                    }
                case .failed, .cancelled:
                    self.markClosed()
                default:
                    break
                }
            }
            connection.start(queue: .global())
            read()
        }

        func cancel() { connection.cancel() }

        private func markClosed() {
            lock.lock()
            didClose = true
            lock.unlock()
        }

        private func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data {
                    self.lock.lock()
                    self.received += self.framer.ingest(data)
                    self.lock.unlock()
                }
                if complete || error != nil {
                    self.markClosed()
                } else {
                    self.read()
                }
            }
        }
    }
}
