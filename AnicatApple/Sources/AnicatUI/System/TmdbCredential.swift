import Foundation

/// Where cinema mode's TMDB credential comes from.
///
/// Not from the viewer, by default. TMDB's own signup is an account, an email
/// confirmation and a developer-plan form asking for an application name, a
/// URL, a postal address and a phone number -- on a page TMDB's docs say is
/// not built for mobile at all. Asking every viewer to walk that before they
/// can see a film is the whole reason cinema mode sat unreachable.
///
/// So a build carries one of two things, and the first is much the better:
///
/// 1. **A proxy URL** (`ANICAT_TMDB_PROXY`, or `ANICATTMDBProxy` in the
///    bundle). The key lives on the proxy and no credential ships at all.
///    This is the only arrangement in which the key genuinely cannot be
///    extracted: an Info.plist entry is plain text, a constant in the binary
///    is one `strings` away, and obfuscation only decides how many minutes it
///    takes. See `services/tmdb-proxy/`.
/// 2. **A key** (`ANICAT_TMDB_KEY`, or `ANICATTMDBKey` in the bundle), for a
///    dev build or a build with no proxy behind it. It ships inside the app
///    and should be treated as public and rotatable, not as a secret.
///
/// A viewer's own key in Settings (`anicat_tmdb_key`) beats both and goes
/// straight to TMDB -- their quota, their request, no reason to spend the
/// proxy's.
///
/// Nothing here is ever committed: the repo is public, and there is no
/// default literal for either.
public enum TmdbCredential {
    /// Settings writes this; a viewer's own key wins over the shipped one.
    public static let userKeyDefaultsKey = "anicat_tmdb_key"

    static let environmentVariable = "ANICAT_TMDB_KEY"
    static let infoPlistKey = "ANICATTMDBKey"
    static let proxyEnvironmentVariable = "ANICAT_TMDB_PROXY"
    static let proxyInfoPlistKey = "ANICATTMDBProxy"

    /// The proxy to build the engine with, or nil when this build ships none.
    /// Not a viewer-facing setting: which server the app talks to is decided
    /// by whoever packaged it, not by whoever is using it.
    public static var proxyURL: String? {
        if let env = clean(ProcessInfo.processInfo.environment[proxyEnvironmentVariable]) {
            return env
        }
        return clean(Bundle.main.object(forInfoDictionaryKey: proxyInfoPlistKey) as? String)
    }

    /// The key to build the engine with, or nil when there is none. Cinema
    /// mode stays hidden only when there is neither this nor a proxy.
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

    /// A blank string is not a key, and neither is a shell variable that was
    /// never expanded. Both the defaults entry and the Info.plist entry exist
    /// even when nothing filled them in -- the packaging script writes the
    /// plist key unconditionally -- so an empty value has to read as absent or
    /// the engine is handed "" and every TMDB call fails on a credential that
    /// looks present. `xcodegen` is worse than empty: with the variable unset
    /// it copies "${ANICAT_TMDB_PROXY}" into the plist verbatim, so cinema
    /// mode read as available and every request went to a hostname that does
    /// not exist.
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$") else { return nil }
        return trimmed
    }
}
