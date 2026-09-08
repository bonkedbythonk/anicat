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

    public func disconnect() {
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

    private func handle(_ frame: RemoteFrame) {
        switch frame {
        case .helloAck(let accepted, let name):
            hostName = name
            status = accepted ? .connected : .denied
            if accepted, let connection {
                for command in queued { connection.sendFrame(.command(command)) }
            }
            queued.removeAll()
        case .state(let incoming):
            state = incoming
        case .hello, .command:
            break
        }
    }
}
