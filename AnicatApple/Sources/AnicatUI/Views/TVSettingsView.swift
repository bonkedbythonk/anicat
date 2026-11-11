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
/// a Mac (a phone feature). The phone remote is here because the TV is a
/// host the phone drives, the same as the Mac.
struct TVSettingsView: View {
    @Bindable var model: AppModel

    @AppStorage("anicat_sub_dub") private var subDub: String = "Subbed"
    @AppStorage("anicat_autoskip") private var autoSkip: Bool = true
    @AppStorage("anicat_autoplay_next") private var autoPlayNext: Bool = true
    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @AppStorage(TmdbCredential.userKeyDefaultsKey) private var tmdbKey: String = ""
    // `@AppStorage` needs a literal key; `AppModel.isLanSharingEnabled`
    // reads it and its defaults observer starts or stops the listener.
    @AppStorage("anicat_lan_sharing") private var lanSharing: Bool = false
    // Read into state rather than off `UserDefaults` in the body: the paired
    // list is written by `RemoteHost` from a socket callback, which no
    // `@AppStorage` binding observes.
    @State private var pairedCount = RemoteHost.pairedDevices().count

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

    // Two columns, the way tvOS's own Settings is laid out: who and what
    // this is on the left, held still, and the list scrolling on the right.
    // One full-width form under a faded centred title read as a stock
    // screen nobody had designed.
    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            identity
                .frame(width: 560)
                .padding(.top, 140)
            Form {
                account
                playback
                remote
                appearance
                cinema
                storage
                TVSection("About") {
                    AcknowledgementsButton {
                        Text("Acknowledgements")
                    }
                }
            }
        }
        .padding(.horizontal, TVMetrics.gutter)
        .background(SumiTheme.background.ignoresSafeArea())
    }

    private var identity: some View {
        VStack(spacing: 20) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 160))
                .foregroundStyle(SumiTheme.foreground.opacity(0.12))
                .padding(.bottom, 20)
            Text("Anicat")
                .font(.sumiHeading(size: 52, weight: .bold))
                .foregroundStyle(SumiTheme.foreground)
            Text(model.isSignedIn ? "Signed in as \(model.viewer?.name ?? "AniList user")" : "Not signed in")
                .font(.system(size: 24))
                .foregroundStyle(SumiTheme.muted)
            Text("Version \(Self.version)")
                .font(.system(size: 22)).monospacedDigit()
                .foregroundStyle(SumiTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Account

    @ViewBuilder
    private var account: some View {
        TVSection("AniList") {
            if model.isSignedIn {
                HStack(spacing: 20) {
                    avatar
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.viewer?.name ?? "AniList User")
                            .font(.system(size: 28, weight: .semibold))
                        Text("Signed in")
                            .font(.system(size: 20))
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
        TVSection("Playback") {
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

    // MARK: Remote

    @ViewBuilder
    private var remote: some View {
        TVSection("iPhone remote") {
            Toggle("Allow iPhones to find this Apple TV", isOn: $lanSharing)
            Text(lanSharing
                 ? "Anicat on an iPhone on this network can control playback here and send episodes to it. The first time one asks, this Apple TV asks you first. Only while Anicat is open."
                 : "Off, nothing on the network can tell Anicat is running.")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            if let name = RemoteHost.shared.attachedRemoteName {
                Label("\(name) connected", systemImage: "iphone")
                    .foregroundStyle(.secondary)
            }
            if pairedCount > 0 {
                Button("Forget \(pairedCount) paired iPhone\(pairedCount == 1 ? "" : "s")", role: .destructive) {
                    RemoteHost.shared.unpairAll()
                    pairedCount = 0
                }
            }
        }
        .onAppear { pairedCount = RemoteHost.pairedDevices().count }
    }

    // MARK: Appearance

    @ViewBuilder
    private var appearance: some View {
        TVSection("Appearance") {
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
        TVSection("Films & TV") {
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
        TVSection("Storage") {
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
/// A form section whose header keeps its own case. tvOS sets section
/// headers in tracked capitals, which the house style retired, and
/// `.textCase(nil)` on the form does not reach them: each header has to say
/// it itself.
private struct TVSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title).textCase(nil)
        }
    }
}
#endif
