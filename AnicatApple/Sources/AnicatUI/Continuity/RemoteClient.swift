import Foundation
import Network
import Observation

/// The phone's side of the remote: one connection to a discovered Mac,
/// commands out, state in.
///
/// Connected on demand rather than whenever a Mac is in range. The first
/// `hello` from an unknown device raises an approval alert on the Mac, and
/// a phone that dialled in by itself would throw that alert at whoever is
/// sitting there with nobody having asked for a remote.
@MainActor
@Observable
public final class RemoteClient {
    public static let shared = RemoteClient()

    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        /// Reached the Mac; waiting for someone there to approve this phone.
        case awaitingApproval
        case connected
        case denied
        case failed(String)
    }

    public private(set) var status: Status = .idle
    public private(set) var state = RemoteState()
    public private(set) var hostName: String?

    private var connection: NWConnection?
    private var framer = RemoteFramer()
    /// Commands sent before the Mac approved this phone. "Play this on the
    /// Mac" from a detail page is one tap that has to survive an approval
    /// alert someone has to walk over and answer; dropping it would make the
    /// first ever use of the feature look broken.
    private var queued: [RemoteCommand] = []

    static let deviceIdKey = "anicat_remote_device_id"
    /// Macs that have already approved this phone, by service name. Only
    /// these are dialled without a tap: a `hello` from an unknown device is
    /// what raises the approval alert over there, and a phone that dialled
    /// every Mac it saw would throw that alert at whoever is sitting at one.
    static let knownHostsKey = "anicat_remote_known_hosts"

    /// True while this connection exists only to exchange remembered
    /// releases, so it hangs up as soon as the reply lands instead of
    /// leaving the Mac pushing state at 1 Hz for as long as the phone is
    /// open.
    private var isQuietSync = false
    private var quietSyncTimeout: Task<Void, Never>?
    private var pendingResolves: [String: CheckedContinuation<StreamGrant, Error>] = [:]

    private init() {}

    /// This phone's stable identity to the Mac's paired list. A UUID and not
    /// the device name: two phones can carry the same name, and approving
    /// one would silently approve the other.
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    public func connect(to node: BonjourDiscovery.DiscoveredNode) {
        // Not `disconnect()`: it empties the queue, and `send(_:to:)` fills
        // the queue and then calls this.
        connection?.cancel()
        connection = nil
        framer = RemoteFramer()
        state = RemoteState()
        status = .connecting
        hostName = node.name

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(node.host),
            port: NWEndpoint.Port(rawValue: node.controlPort) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch connectionState {
                case .ready:
                    connection.sendFrame(.hello(
                        deviceId: Self.deviceId,
                        deviceName: Platform.deviceName
                    ))
                    // Not `.connected` yet: the Mac may still be showing the
                    // approval alert, and a remote that says it is connected
                    // while every button it offers is being dropped on the
                    // floor is worse than one that says it is waiting.
                    self.status = .awaitingApproval
                case .failed(let error):
                    self.status = .failed(error.localizedDescription)
                case .cancelled:
                    if self.status != .denied { self.status = .idle }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    /// Exchanges remembered releases with a Mac that has approved this phone
    /// before, then hangs up. Silent by design: no UI, and nothing happens
    /// at all for a Mac this phone has never been paired with.
    public func syncQuietly(with node: BonjourDiscovery.DiscoveredNode) {
        guard status == .idle, Self.knownHosts().contains(node.id) else { return }
        isQuietSync = true
        connect(to: node)
        // A stale mDNS record from a Mac that has since quit still accepts a
        // connection long enough to reach `.ready`, and then nobody ever
        // answers the hello. Without this the phone would sit in
        // `.awaitingApproval` forever, on every launch, with no sheet open
        // for anyone to notice.
        quietSyncTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.isQuietSync else { return }
            self.disconnect()
        }
    }

    static func knownHosts() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: knownHostsKey) ?? [])
    }

    private func rememberHost() {
        guard let name = hostName else { return }
        var hosts = Self.knownHosts()
        guard hosts.insert(name).inserted else { return }
        UserDefaults.standard.set(Array(hosts), forKey: Self.knownHostsKey)
    }

    public func disconnect() {
        for (_, continuation) in pendingResolves {
            continuation.resume(throwing: RemoteStreamError.notConnected)
        }
        pendingResolves.removeAll()
        quietSyncTimeout?.cancel()
        quietSyncTimeout = nil
        isQuietSync = false
        connection?.cancel()
        connection = nil
        framer = RemoteFramer()
        state = RemoteState()
        queued.removeAll()
        if status != .denied { status = .idle }
    }

    public func send(_ command: RemoteCommand) {
        guard status == .connected, let connection else {
            queued.append(command)
            return
        }
        connection.sendFrame(.command(command))
    }

    /// Sends a command to the Mac, dialling it up first if this is the first
    /// thing the phone has asked of it.
    public func send(_ command: RemoteCommand, to node: BonjourDiscovery.DiscoveredNode) {
        if status == .connected {
            send(command)
        } else {
            queued.append(command)
            if status != .connecting && status != .awaitingApproval { connect(to: node) }
        }
    }

    /// Moves the scrubber locally before the Mac answers.
    ///
    /// State arrives on a one-second tick, so a released scrub otherwise
    /// snaps back to where it was for up to a second and reads as a seek
    /// that did not take. Overwritten by the next real state.
    public func optimisticallySeek(to seconds: Double) {
        state.currentTime = seconds
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.connection === connection else { return }
                if let data, !data.isEmpty {
                    for frame in self.framer.ingest(data) { self.handle(frame) }
                }
                if isComplete || error != nil {
                    self.disconnect()
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    /// Asks the Mac to resolve an episode and hand back a grant this phone
    /// can read it through.
    ///
    /// Leaves the control connection up afterwards, unlike `syncQuietly`:
    /// the Mac drops every grant when its last approved controller goes, so
    /// hanging up here would revoke the token the player is about to use.
    func resolveOnHost(
        _ ask: StreamAsk,
        on node: BonjourDiscovery.DiscoveredNode
    ) async throws -> StreamGrant {
        if status != .connected {
            isQuietSync = false
            connect(to: node)
            try await waitUntilConnected()
        }
        guard status == .connected, let connection else {
            throw RemoteStreamError.notConnected
        }
        let id = UUID().uuidString
        // A Mac too old to know this frame drops it on the floor -- the
        // framer skips anything it cannot decode, by design, so there is no
        // error to wait for and no reply coming. Without a deadline the
        // continuation is never resumed and the play hangs forever behind a
        // spinner instead of falling back to resolving here.
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.resolveTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.failResolve(id, with: RemoteStreamError.notConnected) }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingResolves[id] = continuation
                connection.sendFrame(.streamResolve(id: id, ask: ask))
            }
        } onCancel: {
            Task { @MainActor in self.failResolve(id, with: CancellationError()) }
        }
    }

    /// Long enough for a real resolve on the Mac -- a cold indexer wave with
    /// several dead candidates behind it is minutes, and `resolveAndPlay`'s
    /// own ceiling for the same work is 120s -- but bounded, so a Mac that
    /// will never answer is not mistaken for one that is still working.
    private static let resolveTimeout = Duration.seconds(130)

    func releaseStream(token: String) {
        connection?.sendFrame(.streamRelease(token: token))
    }

    enum RemoteStreamError: Error, LocalizedError {
        case notConnected
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Could not reach the Mac"
            case .refused(let why): return why
            }
        }
    }

    /// Polls rather than waiting on a continuation because approval is a
    /// human on the other end: the state this waits for can be minutes away
    /// on a first pairing, and every other path already reads `status`.
    private func waitUntilConnected(timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch status {
            case .connected: return
            case .denied, .failed, .idle: throw RemoteStreamError.notConnected
            case .connecting, .awaitingApproval: break
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw RemoteStreamError.notConnected
    }

    private func failResolve(_ id: String, with error: Error) {
        pendingResolves.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handle(_ frame: RemoteFrame) {
        switch frame {
        case .helloAck(let accepted, let name):
            hostName = name
            status = accepted ? .connected : .denied
            if accepted, let connection {
                rememberHost()
                for command in queued { connection.sendFrame(.command(command)) }
                // Every connection syncs, not just the quiet ones: opening
                // the remote at all means both apps are up and on the same
                // Wi-Fi, which is exactly the moment this is free.
                connection.sendFrame(.syncOffer(RemoteSync.export()))
            }
            queued.removeAll()
        case .state(let incoming):
            state = incoming
        case .syncReply(let rows):
            RemoteSync.merge(rows)
            if isQuietSync { disconnect() }
        case .streamResolved(let id, let grant, let error):
            guard let continuation = pendingResolves.removeValue(forKey: id) else { return }
            if let grant {
                continuation.resume(returning: grant)
            } else {
                continuation.resume(throwing: RemoteStreamError.refused(error ?? "the Mac refused"))
            }
        case .hello, .command, .syncOffer, .streamResolve, .streamRelease,
             .helloData, .dataHeader, .dataError:
            break
        }
    }
}
