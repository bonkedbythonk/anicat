import Foundation

/// Where cinema mode's TMDB credential comes from.
///
/// Not from the viewer, by default. TMDB's own signup is an account, an email
/// confirmation and a developer-plan form asking for an application name, a
/// URL, a postal address and a phone number -- on a page TMDB's docs say is
/// not built for mobile at all. Asking every viewer to walk that before they
/// can see a film is the whole reason cinema mode sat unreachable.
///
/// So the app carries a key, and the three sources below are tried in order:
///
/// 1. `anicat_tmdb_key` in UserDefaults -- Settings' own field, for anyone
///    who would rather spend their own quota than share the app's.
/// 2. `ANICAT_TMDB_KEY` in the environment -- how a dev build gets one
///    without the key ever reaching a file in the repo.
/// 3. `ANICATTMDBKey` in the bundle's Info.plist -- what
///    `package-anicat-macos-app.sh` writes from that same environment
///    variable, since a packaged .app has no environment to read.
///
/// Nothing here is a secret in the cryptographic sense: a key shipped inside
/// a distributed binary can be read back out of it, and the honest model is a
/// shared key that can be rotated if it is ever abused. What it must never be
/// is committed -- the repo is public -- which is why there is no fourth
/// source and no default literal.
public enum TmdbCredential {
    /// Settings writes this; a viewer's own key wins over the shipped one.
    public static let userKeyDefaultsKey = "anicat_tmdb_key"

    static let environmentVariable = "ANICAT_TMDB_KEY"
    static let infoPlistKey = "ANICATTMDBKey"

    /// The key to build the engine with, or nil when there is none and cinema
    /// mode should stay hidden.
    public static var key: String? {
        if let user = clean(UserDefaults.standard.string(forKey: userKeyDefaultsKey)) {
            return user
        }
        if let env = clean(ProcessInfo.processInfo.environment[environmentVariable]) {
            return env
        }
        return clean(Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    /// Whether the viewer supplied their own key, which is what Settings shows
    /// in place of "using the built-in key".
    public static var isUserSupplied: Bool {
        clean(UserDefaults.standard.string(forKey: userKeyDefaultsKey)) != nil
    }

    /// A blank string is not a key. Both the defaults entry and the Info.plist
    /// entry exist even when nothing filled them in -- the packaging script
    /// writes the plist key unconditionally -- so an empty value has to read
    /// as absent or the engine is handed "" and every TMDB call fails on a
    /// credential that looks present.
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
