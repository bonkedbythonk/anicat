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
    @AppStorage("anicat_autoskip") private var autoSkip: Bool = true
    @AppStorage("anicat_autoplay_next") private var autoPlayNext: Bool = true
    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @AppStorage("anicat_notify_new_episodes") private var notifyNewEpisodes: Bool = false
    @AppStorage(FeedbackDefaults.hapticsKey) private var haptics: Bool = true

    @State private var tokenInput = ""
    @State private var isConnecting = false
    @State private var authFailure: String?
    @State private var confirmingDisconnect = false

    private static let authorizeURL = URL(
        string: "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token"
    )!

    var body: some View {
        Form {
            account
            playback
            appearance
            notifications
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
            Toggle("Skip intros", isOn: $autoSkip)
            Toggle("Play next episode", isOn: $autoPlayNext)
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
                get: { ThemeStore.shared.theme },
                set: { ThemeStore.shared.select($0) }
            )) {
                ForEach(AnicatTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            Picker("Time", selection: $timeFormat) {
                Text("24-hour").tag("24-hour")
                Text("12-hour").tag("12-hour")
            }
            Toggle("Haptics", isOn: $haptics)
        }
    }

    // MARK: Notifications

    @ViewBuilder
    private var notifications: some View {
        Section("Notifications") {
            Toggle("New episodes", isOn: $notifyNewEpisodes)
        }
    }
}
#endif
