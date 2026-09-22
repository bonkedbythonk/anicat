import Foundation

/// The environment switches the test harness drives the app with
/// (`ANICAT_FAKE_VERSION`, `ANICAT_SCREENSHOT_MODE`, `ANICAT_DEBUG_PLAY_FILE`,
/// `ANICAT_DEBUG_SHADERS`, `ANICAT_PLAYER_DEBUG`, `ANICAT_NO_AUTO_FULLSCREEN`,
/// `ANICAT_NO_HOVER_GATE`, `ANICAT_NOTIFY_TEST`). Read through here so a
/// release build answers `nil` to every one of them: they shipped in 1.0.x
/// as live switches in the public binary, and anything that can launch the
/// app with an environment (a launch agent, a shell alias, another process)
/// could pick the version it claims to be, swap the shader chain for
/// arbitrary files or point the player at a path. `dev-run.sh` builds debug,
/// so the harness keeps working there.
public enum DebugHooks {
    public static func env(_ key: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[key]
        #else
        return nil
        #endif
    }
}
