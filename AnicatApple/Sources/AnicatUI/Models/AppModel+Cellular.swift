#if os(iOS)
import Foundation

public extension AppModel {
    /// A play the viewer started while the phone is on cellular or a
    /// hotspot, held until they say it is worth the data.
    struct CellularPrompt: Identifiable {
        public let id = UUID()
        public let proceed: () -> Void
    }

    static let warnOnCellularKey = "anicat_warn_on_cellular"

    static var isCellularWarningEnabled: Bool {
        UserDefaults.standard.object(forKey: warnOnCellularKey) as? Bool ?? true
    }

    /// Runs `action`, or raises the cellular prompt first.
    ///
    /// Wrapped around the two places the phone starts a stream from a tap --
    /// Continue Watching and an episode row -- and deliberately not around
    /// next/previous inside the player: by then the episode being paid for
    /// is already playing, and a dialog between episodes is a nag rather
    /// than a warning.
    func playGuardedByCellular(_ action: @escaping () -> Void) {
        guard Self.isCellularWarningEnabled, NetworkReachability.shared.isExpensive else {
            action()
            return
        }
        cellularPrompt = CellularPrompt(proceed: action)
    }
}
#endif
