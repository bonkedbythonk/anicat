#if os(tvOS)
import SwiftUI

/// Settings on Apple TV, as the fourth tab.
///
/// The account section is why this exists: it is the only "Connect AniList"
/// the TV has. There is no browser on a television, so the sign-in is the
/// implicit-grant flow done on another device -- the authorize address is
/// shown on screen, the viewer opens it on a phone or a Mac, and types the
/// token the redirect hands back into the field here with the on-screen
/// keyboard. Long, but once.
///
/// Every other row is a key something on the TV actually reads. Absent on
/// purpose: GPU upscaling (the shader chain never runs off a Mac), the
/// keyboard dimmer, Discord presence, the cellular warning, streaming from
/// a Mac (a phone feature), and notifications (a TV notification is a
/// badge and nothing else).
struct TVSettingsView: View {
    @Bindable var model: AppModel

    @AppStorage("anicat_sub_dub") private var subDub: String = "Subbed"
    @AppStorage("anicat_autoskip") private var autoSkip: Bool = true
    @AppStorage("anicat_autoplay_next") private var autoPlayNext: Bool = true
    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @AppStorage(TmdbCredential.userKeyDefaultsKey) private var tmdbKey: String = ""

    // The theme controls gate view structure on `skin.hasLight`, so the
    // reads have to be observed ones. See `PhoneSettingsView`.
    @State private var store = ThemeStore.shared

    @State private var tokenInput = ""
    @State private var isConnecting = false
    @State private var authFailure: String?
    @State private var confirmingDisconnect = false
    @State private var cacheBytes: UInt64?
    @State private var isPurging = false

    private static let authorizeURL = "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token"

    var body: some View {
        Form {
            account
            playback
            appearance
            cinema
            storage
            Section("About") {
                AcknowledgementsButton {
                    Text("Acknowledgements")
                }
                LabeledContent("Version", value: Self.version)
            }
        }
        .background(SumiTheme.background)
        .navigationTitle("Settings")
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Account

    @ViewBuilder
    private var account: some View {
        Section("AniList") {
            if model.isSignedIn {
                HStack(spacing: 20) {
                    avatar
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.viewer?.name ?? "AniList User")
                            .font(.system(size: 28, weight: .semibold))
                        Text("Signed in")
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Button(confirmingDisconnect ? "Press again to disconnect" : "Disconnect", role: .destructive) {
                    if confirmingDisconnect {
                        model.signOut()
                        confirmingDisconnect = false
                    } else {
                        confirmingDisconnect = true
                    }
                }
            } else {
                Text("Browsing and playback work without an account. Your lists and progress tracking need one.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("On your phone or computer, open:")
                        .font(.system(size: 22))
                    Text(Self.authorizeURL)
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(SumiTheme.indigo)
                        .textCase(nil)
                    Text("Sign in, then paste the address it sends you to (or just the token) below.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }

                // AniList's implicit grant hands the token back in the
                // redirect URL's fragment, so the whole URL is accepted;
                // `signIn` takes either that or the bare token.
                TextField("Redirect URL or token", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 22, design: .monospaced))
                    .onSubmit { connect() }

                Button(isConnecting ? "Connecting…" : "Connect") { connect() }
                    .disabled(isConnecting || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let authFailure {
                    Text(authFailure)
                        .font(.system(size: 20))
                        .foregroundStyle(SumiTheme.warning)
                }
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatar = model.viewer?.avatarUrl.flatMap(URL.init(string:)) {
            CachedAsyncImage(url: avatar, maxPixelSize: 160) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                SumiTheme.card
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
        }
    }

    private func connect() {
        let raw = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isConnecting else { return }
        isConnecting = true
        authFailure = nil
        Task {
            await model.signIn(token: Self.extractToken(from: raw))
            isConnecting = false
            if model.isSignedIn {
                tokenInput = ""
            } else {
                authFailure = model.errorMessage ?? "AniList did not accept that token."
            }
        }
    }

    /// The bare token out of whatever was typed: the redirect URL's
    /// fragment (`#access_token=...&token_type=Bearer`), a query form of the
    /// same, or the token on its own.
    static func extractToken(from raw: String) -> String {
        for separator in ["#", "?"] {
            if let range = raw.range(of: separator) {
                let fragment = raw[range.upperBound...]
                for pair in fragment.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    if parts.count == 2, parts[0] == "access_token" {
                        return String(parts[1])
                    }
                }
            }
        }
        return raw
    }

    // MARK: Playback

    @ViewBuilder
    private var playback: some View {
        Section("Playback") {
            Picker("Audio", selection: $subDub) {
                Text("Subbed").tag("Subbed")
                Text("Dubbed").tag("Dubbed")
            }
            Toggle("Skip intros and outros automatically", isOn: $autoSkip)
                .onChange(of: autoSkip) { _, on in
                    model.playerController.autoSkipEnabled = on
                }
            Toggle("Play the next episode automatically", isOn: $autoPlayNext)
        }
    }

    // MARK: Appearance

    @ViewBuilder
    private var appearance: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { store.skin },
                set: { store.select($0) }
            )) {
                ForEach(SumiSkin.allCases, id: \.self) { skin in
                    Text(skin.displayName).tag(skin)
                }
            }
            if store.skin.hasLight {
                Picker("Appearance", selection: Binding(
                    get: { store.appearance },
                    set: { store.select($0) }
                )) {
                    ForEach(AnicatAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
            }
            Picker("Time", selection: $timeFormat) {
                Text("24-hour").tag("24-hour")
                Text("12-hour").tag("12-hour")
            }
        }
    }

    // MARK: Films & TV

    @ViewBuilder
    private var cinema: some View {
        Section("Films & TV") {
            if model.cinemaAvailable {
                Label("TMDB connected", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("Add a TMDB API key to browse films and series. Free from themoviedb.org.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            TextField("TMDB API key", text: $tmdbKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 22, design: .monospaced))
            Text("Takes effect as you type it.")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Storage

    /// What streaming has left on disk, and a way to be rid of it. tvOS may
    /// also clear it on its own under storage pressure, which is why the
    /// cache lives where it does; see `AppModel.makeEngineDataDirectory`.
    @ViewBuilder
    private var storage: some View {
        Section("Storage") {
            LabeledContent("Stream cache", value: cacheBytes.map(Self.formatted) ?? "—")
            Button(isPurging ? "Clearing…" : "Clear now") {
                isPurging = true
                Task {
                    await model.purgeStreamCache()
                    cacheBytes = await model.streamCacheBytes()
                    isPurging = false
                }
            }
            .disabled(isPurging || (cacheBytes ?? 0) == 0)
            Text("Whatever is playing is kept.")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .task { cacheBytes = await model.streamCacheBytes() }
    }

    static func formatted(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "Empty" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
#endif
