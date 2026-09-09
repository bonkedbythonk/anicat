#if os(iOS)
import SwiftUI

/// Settings on iPhone, reached from the Up Next bar rather than a tab.
///
/// The account section is the reason this screen had to exist at all, not a
/// convenience: `anicat_onboarding_seen` records the dismissal, so one tap on
/// "Skip for now" retired the only "Connect AniList" button the phone had.
/// Up Next and Library then stayed empty forever and deleting the app was the
/// only way back in.
///
/// Every other row here is a key something on the phone actually reads.
/// Deliberately absent, because nothing on iOS reads them: GPU upscaling
/// (Anime4K never runs here), the keyboard backlight dimmer (a MacBook
/// feature), Discord presence (unix-socket IPC, which the sandbox has no
/// counterpart for), and the TMDB key (cinema is not in the phone's scope).
struct PhoneSettingsView: View {
    @Bindable var model: AppModel

    @AppStorage("anicat_sub_dub") private var subDub: String = "Subbed"
    @AppStorage("anicat_autoskip") private var autoSkip: Bool = false
    @AppStorage("anicat_autoplay_next") private var autoPlayNext: Bool = true
    // `AppModel.isCellularWarningEnabled` owns the reader and the default;
    // `@AppStorage` needs a literal here, so the two must agree.
    @AppStorage("anicat_warn_on_cellular") private var warnOnCellular: Bool = true
    // `AppModel.isStreamFromMacEnabled` owns the reader and the default.
    @AppStorage("anicat_stream_from_mac") private var streamFromMac: Bool = true
    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @AppStorage("anicat_notify_new_episodes") private var notifyNewEpisodes: Bool = false
    @AppStorage(TmdbCredential.userKeyDefaultsKey) private var tmdbKey: String = ""

    // The theme controls gate view *structure* on `skin.hasLight` and on
    // `appearance`, so those reads have to be observed ones — off
    // `ThemeStore.shared` inline the toggle would stay on screen after a
    // switch to OLED until something else redrew the Form.
    @State private var store = ThemeStore.shared

    @State private var tokenInput = ""
    @State private var isConnecting = false
    @State private var authFailure: String?
    @State private var confirmingDisconnect = false
    @State private var cacheBytes: UInt64?
    @State private var isPurging = false

    private static let authorizeURL = URL(
        string: "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token"
    )!

    var body: some View {
        Form {
            account
            playback
            appearance
            storage
            notifications
            cinema
        }
        .scrollContentBackground(.hidden)
        .background(SumiTheme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Account

    @ViewBuilder
    private var account: some View {
        Section("AniList") {
            if model.isSignedIn {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.viewer?.name ?? "AniList User")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SumiTheme.foreground)
                        Text("Signed in")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(SumiTheme.muted)
                    }
                }
                Button(confirmingDisconnect ? "Tap again to disconnect" : "Disconnect", role: .destructive) {
                    if confirmingDisconnect {
                        model.signOut()
                        confirmingDisconnect = false
                    } else {
                        confirmingDisconnect = true
                    }
                }
            } else {
                Text("Browsing and playback work without an account. Your lists and progress tracking need one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SumiTheme.muted)

                Button("Authorize in your browser") {
                    Platform.openExternal(Self.authorizeURL)
                }

                // AniList's implicit grant hands the token back in the
                // redirect URL's fragment, so the whole URL is what the
                // viewer has to hand; `signIn` takes either that or the bare
                // token.
                HStack(spacing: 10) {
                    TextField("Redirect URL or token", text: $tokenInput, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                    // Handed to the live engine; it reads the key once at
                    // construction, so without this the field did nothing
                    // until the app was started again.
                    .onChange(of: tmdbKey) { _, _ in AppModel.shared?.applyTmdbKey() }

                    // `PasteButton`, not a long press on the field and not a
                    // `UIPasteboard.general.string` read behind a plain
                    // button: the gesture is unreliable on a token this long
                    // (the callout can land off screen with the keyboard up),
                    // and reading the pasteboard in code raises the system's
                    // "allow paste" prompt every time. This is the one paste
                    // affordance that neither asks nor needs the gesture.
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first else { return }
                        tokenInput = pasted
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }

                Button(isConnecting ? "Connecting…" : "Connect") {
                    connect()
                }
                .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)

                if let authFailure {
                    Text(authFailure)
                        .font(.system(size: 12))
                        .foregroundStyle(SumiTheme.danger)
                }
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        CachedAsyncImage(url: model.viewer?.avatarUrl.flatMap(URL.init(string:)), maxPixelSize: 160) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            SumiTheme.card
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func connect() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isConnecting else { return }
        isConnecting = true
        authFailure = nil
        Task { @MainActor in
            await model.signIn(token: token)
            isConnecting = false
            if model.isSignedIn {
                tokenInput = ""
                await model.refreshAll()
            } else {
                // `signIn` also raises the global banner, but the message
                // belongs next to the field being looked at.
                authFailure = "AniList did not accept that. Paste the whole URL from the browser's address bar after authorizing."
                model.errorMessage = nil
            }
        }
    }

    // MARK: Playback

    @ViewBuilder
    private var playback: some View {
        Section("Playback") {
            Picker("Audio", selection: $subDub) {
                Text("Subbed").tag("Subbed")
                Text("Dubbed").tag("Dubbed")
            }
            // A dub preference is a preference, not a filter — the engine
            // penalises non-dub releases and refunds the penalty when a show
            // has no dub at all.
            Toggle("Skip intros automatically", isOn: $autoSkip)
            Text(autoSkip
                 ? "Intros are skipped without asking."
                 : "A Skip Intro button appears instead.")
                .font(.system(size: 11.5))
                .foregroundStyle(SumiTheme.muted)
            Toggle("Play next episode", isOn: $autoPlayNext)
            Toggle("Warn on cellular", isOn: $warnOnCellular)
            Text("Asked before each episode you start off Wi-Fi. Personal hotspots count.")
                .font(.system(size: 11.5))
                .foregroundStyle(SumiTheme.muted)
            Toggle("Stream from Mac when available", isOn: $streamFromMac)
            Text("Plays through a Mac running Anicat on this Wi-Fi, so the phone joins no swarm and stores nothing. Falls back to streaming here when no Mac answers.")
                .font(.system(size: 11.5))
                .foregroundStyle(SumiTheme.muted)
        }
    }

    // MARK: Appearance

    @ViewBuilder
    private var appearance: some View {
        Section("Appearance") {
            // Bound to the store, not to `@AppStorage("anicat_theme")`:
            // writing the key alone changes the stored value without
            // rebuilding the palette, so the app keeps the old colours until
            // the next launch.
            Picker("Theme", selection: Binding(
                get: { store.skin },
                set: { store.select($0) }
            )) {
                ForEach(SumiSkin.allCases) { skin in
                    Text(skin.displayName).tag(skin)
                }
            }
            // OLED has no light half, so it gets no appearance control at all
            // rather than one whose Light does nothing.
            if store.skin.hasLight {
                Toggle("Follow system appearance", isOn: Binding(
                    get: { store.appearance == .system },
                    set: { follows in
                        // Leaving Follow system lands on the side the system
                        // was already showing, so the toggle never changes the
                        // colours by itself.
                        store.select(follows
                            ? .system
                            : (ThemeStore.systemPrefersDark ? .dark : .light))
                    }
                ))
                if store.appearance != .system {
                    Picker("Appearance", selection: Binding(
                        get: { store.appearance },
                        set: { store.select($0) }
                    )) {
                        Text("Light").tag(AnicatAppearance.light)
                        Text("Dark").tag(AnicatAppearance.dark)
                    }
                    .pickerStyle(.segmented)
                }
            }
            Picker("Time", selection: $timeFormat) {
                Text("24-hour").tag("24-hour")
                Text("12-hour").tag("12-hour")
            }
        }
    }

    // MARK: Notifications

    /// Cinema needs a TMDB credential the anime side does not. A build can
    /// ship a proxy in its Info.plist; this is the other route, and the only
    /// one a sideloaded build can take without being rebuilt.
    @ViewBuilder
    private var cinema: some View {
        Section("Films & TV") {
            if model.cinemaAvailable {
                Label("TMDB connected", systemImage: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(SumiTheme.muted)
            } else {
                Text("Add a TMDB API key to browse films and series. Free from themoviedb.org.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SumiTheme.muted)
            }
            HStack(spacing: 10) {
                TextField("TMDB API key", text: $tmdbKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    tmdbKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
            }
            Text("Takes effect as you type it.")
                .font(.system(size: 11.5))
                .foregroundStyle(SumiTheme.muted)
        }
    }

    /// What streaming has left on disk, and a way to be rid of it.
    ///
    /// Worth showing rather than leaving implicit: the cache is capped at
    /// 3 GiB, which is a rounding error on a Mac and 2.5% of a 128 GB phone
    /// for episodes already watched. It is emptied automatically when the
    /// app is backgrounded; this is the same thing on demand, and the number
    /// is what makes that behaviour believable.
    @ViewBuilder
    private var storage: some View {
        Section("Storage") {
            HStack {
                Text("Stream cache")
                    .font(.system(size: 15))
                Spacer()
                Text(cacheBytes.map(Self.formatted) ?? "—")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(SumiTheme.muted)
            }
            Button(isPurging ? "Clearing…" : "Clear now") {
                isPurging = true
                Task {
                    await model.purgeStreamCache()
                    cacheBytes = await model.streamCacheBytes()
                    isPurging = false
                }
            }
            .disabled(isPurging || (cacheBytes ?? 0) == 0)
            Text("Cleared automatically when you leave the app. Whatever is playing is kept.")
                .font(.system(size: 11.5))
                .foregroundStyle(SumiTheme.muted)
        }
        .task { cacheBytes = await model.streamCacheBytes() }
    }

    static func formatted(_ bytes: UInt64) -> String {
        // ByteCountFormatter renders 0 as "Zero KB", which reads like a unit
        // conversion went wrong rather than like an empty cache.
        guard bytes > 0 else { return "Empty" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    @ViewBuilder
    private var notifications: some View {
        Section("Notifications") {
            Toggle("New episodes", isOn: $notifyNewEpisodes)
        }
    }
}
#endif
