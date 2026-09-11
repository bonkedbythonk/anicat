import Foundation

/// The player's diagnostic lines (size checks, sampler timings), kept as
/// a name so the call sites read as what they are. They go to the app
/// log (`AppLog`): this used to be its own `player.log`, which meant a
/// report about a stall needed that file *and* the engine's stderr, and
/// the second one nobody launched from the Dock ever had.
enum PlayerLog {
    static func write(_ line: String) {
        AppLog.write(line)
    }
}
