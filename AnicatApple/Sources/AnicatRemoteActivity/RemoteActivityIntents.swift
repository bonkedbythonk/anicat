#if os(iOS)
import AppIntents
import Foundation

/// The verbs a Live Activity button can ask for.
public enum RemoteActivityCommand: String, Sendable {
    case playPause
    case back10
    case forward10
    case skipWindow
}

/// How an intent running in the app process reaches the remote.
///
/// A closure the app installs rather than a direct call: this target
/// deliberately depends on nothing, and the widget extension links it. The
/// intent itself is compiled into both, but `LiveActivityIntent.perform`
/// runs in the *app*, which is where the socket lives -- so the handler is
/// there when it matters and nil in the extension, where sending would be
/// impossible anyway.
public final class RemoteActivityBridge: @unchecked Sendable {
    public static let shared = RemoteActivityBridge()
    private init() {}

    public var handler: (@Sendable (RemoteActivityCommand) -> Void)?
}

public struct RemoteActivityButtonIntent: LiveActivityIntent {
    // `let`, not `var`: Swift 6 treats a mutable static as shared mutable
    // state and refuses it outright, and AppIntents only ever reads these.
    public static let title: LocalizedStringResource = "Anicat Remote"
    public static let description = IntentDescription("Controls what the Mac is playing.")
    /// Runs in the app process, not the widget's: the connection to the Mac
    /// is there, and reopening one per button press would raise a fresh
    /// pairing handshake for every tap.
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Command")
    public var command: String

    public init() { self.command = "" }

    public init(command: RemoteActivityCommand) {
        self.command = command.rawValue
    }

    public func perform() async throws -> some IntentResult {
        if let parsed = RemoteActivityCommand(rawValue: command) {
            RemoteActivityBridge.shared.handler?(parsed)
        }
        return .result()
    }
}
#endif
