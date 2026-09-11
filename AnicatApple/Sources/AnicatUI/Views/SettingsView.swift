import SwiftUI

public struct SettingsView: View {
    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case playback = "Playback"
        case sharing = "Sharing"
        case accounts = "Accounts"
        case advanced = "Advanced"

        public var id: String { rawValue }

        public var iconName: String {
            switch self {
            case .general: return "gearshape.fill"
            case .playback: return "play.circle.fill"
            case .sharing: return "antenna.radiowaves.left.and.right"
            case .accounts: return "person.crop.circle"
            case .advanced: return "wrench.and.screwdriver.fill"
            }
        }
    }

    // Tab Navigation
    @State private var selectedTab: SettingsTab = .general
    @State private var searchQuery = ""
    @Namespace private var settingsNavNamespace

    // Maintenance card's "Copy Debug Report" feedback also renders in
    // `headerSection` above the tab rail, so it stays here rather than
    // moving into `MaintenanceTabSection` with the rest of that tab's state.
    @State private var copyFeedback: String? = nil

    enum MaintenanceActionState {
        case idle
        case confirming
        case working
        case done
    }

    public let isSignedIn: Bool
    public let username: String?
    public let avatarUrl: String?
    public let onSaveToken: (String) -> Void
    public let onDisconnectAniList: () -> Void
    public let onClearRegistry: () async -> Bool
    /// Reset onboarding: besides clearing the seen flag, shows the screen
    /// again right away, so an already signed-in user can actually see what
    /// they are resetting instead of waiting for a token-less launch.
    public let onResetOnboarding: () -> Void
    public let onOpenShortcuts: (() -> Void)?

    public init(
        isSignedIn: Bool = false,
        username: String? = nil,
        avatarUrl: String? = nil,
        initialTab: SettingsTab = .general,
        onSaveToken: @escaping (String) -> Void = { _ in },
        onDisconnectAniList: @escaping () -> Void = {},
        onClearRegistry: @escaping () async -> Bool = { false },
        onResetOnboarding: @escaping () -> Void = {},
        onOpenShortcuts: (() -> Void)? = nil
    ) {
        self.isSignedIn = isSignedIn
        self.username = username
        self.avatarUrl = avatarUrl
        self.onClearRegistry = onClearRegistry
        self.onResetOnboarding = onResetOnboarding
        self._selectedTab = State(initialValue: initialTab)
        self.onSaveToken = onSaveToken
        self.onDisconnectAniList = onDisconnectAniList
        self.onOpenShortcuts = onOpenShortcuts
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                headerSection

                // Two-Column Layout
                HStack(alignment: .top, spacing: 28) {
                    // Left Column: Vertical Tab List (~180px)
                    leftNavRail
                        .frame(width: 180)

                    // Right Column: Settings Cards
                    // Each tab below is its own View struct rather than a
                    // computed property inlined here: every AppStorage
                    // toggle and confirm-flow @State (disconnect, wipe
                    // registry, reset onboarding) used to live inside this
                    // 1236-line body, so flipping one switch re-evaluated
                    // all four tabs' worth of layout, not just the one
                    // showing.
                    VStack(alignment: .leading, spacing: 20) {
                        if !searchQuery.isEmpty {
                            searchResults
                        } else {
                        switch selectedTab {
                        case .general:
                            GeneralTabSection(onOpenShortcuts: onOpenShortcuts)
                        case .playback:
                            PlaybackTabSection()
                        case .sharing:
                            SharingTabSection()
                        case .accounts:
                            AccountTabSection(
                                isSignedIn: isSignedIn,
                                username: username,
                                avatarUrl: avatarUrl,
                                onSaveToken: onSaveToken,
                                onDisconnectAniList: onDisconnectAniList
                            )
                        case .advanced:
                            MaintenanceTabSection(
                                isSignedIn: isSignedIn,
                                username: username,
                                onClearRegistry: onClearRegistry,
                                onResetOnboarding: onResetOnboarding,
                                copyFeedback: $copyFeedback
                            )
                        }
                        }
                    }
                    .animation(.smooth, value: selectedTab)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(SumiTheme.background)
    }

    /// Where each control lives, for the search field.
    ///
    /// Hand-kept rather than derived: the controls are `SettingField`s built
    /// inside `@ViewBuilder` bodies, so there is no list of them to read at
    /// runtime without inventing one and threading it through five tab
    /// structs. **Add a row here when you add a control**, or search will
    /// quietly fail to find it -- the one real cost of doing it this way.
    struct IndexEntry: Identifiable {
        let label: String
        let card: String
        let tab: SettingsTab
        var id: String { "\(tab.rawValue)/\(card)/\(label)" }
    }

    static let searchIndex: [IndexEntry] = [
        .init(label: "Theme", card: "Appearance", tab: .general),
        .init(label: "Follow System Appearance", card: "Appearance", tab: .general),
        .init(label: "Appearance", card: "Appearance", tab: .general),
        .init(label: "Time Format", card: "Appearance", tab: .general),
        .init(label: "Keyboard shortcuts cheat sheet", card: "Keyboard Shortcuts", tab: .general),

        .init(label: "Sub/Dub", card: "What plays", tab: .playback),
        .init(label: "Auto-Skip Intros", card: "What plays", tab: .playback),
        .init(label: "Play the next episode", card: "What plays", tab: .playback),
        .init(label: "Next episode card", card: "What plays", tab: .playback),
        .init(label: "GPU Upscaling", card: "Video", tab: .playback),
        .init(label: "Hardware Decoding", card: "Video", tab: .playback),
        .init(label: "Ambient Glow", card: "Video", tab: .playback),
        .init(label: "Glow in windowed mode", card: "Video", tab: .playback),
        .init(label: "Dim keyboard backlight", card: "While watching", tab: .playback),
        .init(label: "Night Hours", card: "While watching", tab: .playback),
        .init(label: "Interface Sounds", card: "Sound & haptics", tab: .playback),
        .init(label: "Sound Volume", card: "Sound & haptics", tab: .playback),
        .init(label: "Haptic Feedback", card: "Sound & haptics", tab: .playback),

        .init(label: "New Episode Alerts", card: "Notifications", tab: .sharing),
        .init(label: "Discord Rich Presence", card: "Presence", tab: .sharing),
        .init(label: "Paired iPhones", card: "Devices", tab: .sharing),

        .init(label: "AniList account", card: "AniList", tab: .accounts),
        .init(label: "API Token", card: "AniList", tab: .accounts),
        .init(label: "Your own TMDB key", card: "Cinema (TMDB)", tab: .accounts),

        .init(label: "Offline manga limit", card: "Storage", tab: .advanced),
        .init(label: "Streamed video cache", card: "Storage", tab: .advanced),
        .init(label: "Current version", card: "Updates", tab: .advanced),
        .init(label: "Acknowledgements", card: "Licenses", tab: .advanced),
        .init(label: "Copy Debug Report", card: "Logs & Debugging", tab: .advanced),
        .init(label: "Reveal Log File", card: "Logs & Debugging", tab: .advanced),
        .init(label: "Clear Local Registry", card: "System Maintenance", tab: .advanced),
        .init(label: "Reset Onboarding", card: "System Maintenance", tab: .advanced),
    ]

    private var searchResults: some View {
        let needle = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = Self.searchIndex.filter {
            $0.label.lowercased().contains(needle) || $0.card.lowercased().contains(needle)
        }
        return VStack(alignment: .leading, spacing: 8) {
            if hits.isEmpty {
                Text("Nothing matches \"\(searchQuery)\".")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                    .padding(.vertical, 12)
            } else {
                ForEach(hits) { hit in
                    Button {
                        selectedTab = hit.tab
                        searchQuery = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: hit.tab.iconName)
                                .font(.system(size: 11))
                                .foregroundColor(SumiTheme.muted)
                                .frame(width: 16)
                            Text(hit.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                            Spacer(minLength: 12)
                            Text("\(hit.tab.rawValue) › \(hit.card)")
                                .font(.system(size: 11.5))
                                .foregroundColor(SumiTheme.muted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                }
            }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings")
                    .font(.sumiHeading(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(SumiTheme.foreground)

                Text("Configure playback, appearance, and account")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(SumiTheme.muted)
                TextField("Search settings", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.foreground)
                    .frame(width: 150)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(SumiTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SumiTheme.card)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))

            if let copyFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.successLight)
                    Text(copyFeedback)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.successLight)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Left Nav Rail
    private var leftNavRail: some View {
        VStack(spacing: 3) {
            ForEach(SettingsTab.allCases) { tab in
                let isActive = selectedTab == tab
                Button {
                    if selectedTab != tab {
                        SumiHaptics.selection()
                        withAnimation(.smooth) {
                            selectedTab = tab
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                            .frame(width: 20, alignment: .center)

                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isActive ? .semibold : .medium))

                        Spacer()
                    }
                    .foregroundColor(isActive ? SumiTheme.foreground : SumiTheme.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if isActive {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(SumiTheme.foreground.opacity(0.08))
                                .matchedGeometryEffect(id: "settingsNavHighlight", in: settingsNavNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
        }
        .animation(.snappy, value: selectedTab)
    }

}

// MARK: - Settings Tabs

private struct GeneralTabSection: View {
    let onOpenShortcuts: (() -> Void)?

    // Only keys something reads belong here. This tab used to carry nine
    // more (a three-way style picker, provider and API dropdowns, a cinema
    // toggle with a TMDB token, an e-reader card) that no code outside
    // Settings ever looked up, so every one of them was a control that
    // changed nothing. They come back with the feature that reads them.
    @AppStorage("anicat_time_format") private var selectedTimeFormat: String = "24-hour"
    // The appearance controls gate view *structure* on `skin.hasLight` and on
    // `appearance`, so both reads have to be observed ones.
    @State private var themeStore = ThemeStore.shared

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        SettingsCard(title: "Appearance") {
            SettingField(
                label: "Theme",
                description: "Ink & Index is the original warm sumi-ink skin, Sakura Zen a cherry-dark one with serif titles; both have a light half. OLED is a true black for panels that switch pixels off, and is dark only.",
                isStacked: true
            ) {
                ThemePicker()
            }

            // OLED has no light half, so it gets no appearance control at all
            // rather than one whose Light quietly stays dark.
            if themeStore.skin.hasLight {
                Divider()
                    .background(SumiTheme.border)

                SettingField(
                    label: "Follow System Appearance",
                    description: "Light or dark to match macOS. Turning this off lands on whichever side the system was already showing, so nothing changes colour until you pick."
                ) {
                    SumiSwitch(isOn: Binding(
                        get: { themeStore.appearance == .system },
                        set: { follows in
                            themeStore.select(follows
                                ? .system
                                : (ThemeStore.systemPrefersDark ? .dark : .light))
                        }
                    ))
                }

                if themeStore.appearance != .system {
                    Divider()
                        .background(SumiTheme.border)

                    SettingField(
                        label: "Appearance",
                        description: "Which half of the skin to draw, regardless of macOS."
                    ) {
                        SumiSegmentedControl(
                            options: [("light", "Light"), ("dark", "Dark")],
                            selection: Binding(
                                get: { themeStore.appearance == .light ? "light" : "dark" },
                                set: { themeStore.select($0 == "light" ? .light : .dark) }
                            )
                        )
                    }
                }
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Time Format",
                description: "How dates and times should be displayed."
            ) {
                SumiDropdown(
                    options: ["24-hour", "12-hour (AM/PM)"],
                    selected: $selectedTimeFormat,
                    minWidth: 160
                )
            }
        }

        // Moved off the player tab: the shortcuts are the whole app's, not
        // playback's, and they were the only reference card sitting in a
        // list of switches.
        SettingsCard(title: "Keyboard Shortcuts") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cheat Sheet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)

                    Text("Press ? anywhere in the app to view the keyboard shortcuts cheat sheet.")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }

                Spacer()

                if let onOpenShortcuts {
                    Button(action: onOpenShortcuts) {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 11))
                            Text("View Shortcuts")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(SumiTheme.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.sumiPressable)
                } else {
                    Text("?")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(SumiTheme.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                }
            }
        }
    }
    }
}

/// Playback, split by what each control actually affects.
///
/// This was one "Playback" card holding eleven switches across four
/// unrelated concerns -- what plays, what gets skipped, how the picture is
/// drawn, and what the laptop's keyboard does -- with Discord presence on
/// the end of it. Nothing was findable because nothing was grouped.
private struct PlaybackTabSection: View {
    @AppStorage("anicat_sub_dub") private var subDub: String = "Subtitled"
    @AppStorage("anicat_autoskip") private var autoSkipIntro: Bool = true
    @AppStorage("anicat_autoplay_next") private var autoPlayNext: Bool = true
    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_hardware_decoding") private var hardwareDecoding: Bool = true
    @AppStorage("anicat_ambient_glow") private var ambientGlow: Bool = true
    @AppStorage("anicat_ambient_glow_windowed") private var ambientGlowWindowed: Bool = true
    // `PlayerController.isNextEpisodeCardEnabled` owns the reader and the
    // default; the literal here and the one there must agree.
    @AppStorage("anicat_next_up_card") private var nextUpCard: Bool = true
    // `KeyboardDimSchedule` owns the readers and the defaults, and the
    // literals must agree with them.
    @AppStorage("anicat_keyboard_dim") private var keyboardDim: Bool = false
    @AppStorage("anicat_keyboard_dim_mode") private var keyboardDimMode: String = "night"
    @AppStorage("anicat_keyboard_dim_from") private var keyboardDimFrom: Int = 20
    @AppStorage("anicat_keyboard_dim_until") private var keyboardDimUntil: Int = 7
    // `FeedbackDefaults` owns the readers and the defaults; the literals here
    // and the ones there must agree.
    @AppStorage("anicat_sounds") private var interfaceSounds: Bool = false
    @AppStorage("anicat_sounds_volume") private var interfaceSoundVolume: Double = 0.3
    @AppStorage("anicat_haptics") private var haptics: Bool = true

    private static let hourOptions = (0...23).map { String(format: "%02d:00", $0) }

    /// The two hour keys are stored as integers so the dimmer can compare
    /// them without parsing, and shown as "20:00" so the row reads as a
    /// time. A dropdown of labels over an `Int` binding keeps both.
    private func hourBinding(_ hour: Binding<Int>) -> Binding<String> {
        Binding(
            get: { String(format: "%02d:00", hour.wrappedValue) },
            set: { label in
                if let parsed = Int(label.prefix(2)) { hour.wrappedValue = parsed }
            }
        )
    }

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        SettingsCard(
            title: "What plays",
            description: "Which track is chosen, and what happens at the edges of an episode."
        ) {
            SettingField(
                label: "Sub/Dub",
                description: "Preferred audio language for streaming. A preference, not a filter: a dub wins where one exists, and nothing is hidden where one does not."
            ) {
                SumiDropdown(
                    options: ["Subtitled", "Dubbed"],
                    selected: $subDub,
                    minWidth: 160
                )
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Auto-Skip Intros",
                description: "Automatically skip openings and endings using AniSkip. The video player also displays an on-screen skip button when an intro or outro is detected."
            ) {
                SumiSwitch(isOn: $autoSkipIntro)
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Play the next episode",
                description: "Starts the next episode as the current one ends. The player's own button toggles this too."
            ) {
                SumiSwitch(isOn: $autoPlayNext)
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Next episode card",
                description: "Counts down to the next episode over the ending, with the option to start it now or stay where you are. Turning it off does not turn off auto-play; the next episode simply arrives without asking."
            ) {
                SumiSwitch(isOn: $nextUpCard)
            }
        }

        SettingsCard(
            title: "Video",
            description: "How the picture is decoded and drawn. Both of the first two cost GPU time."
        ) {
            SettingField(
                label: "GPU Upscaling",
                description: "Anime4K — real-time neural upscaling that sharpens lines and adds depth with minimal battery impact. Renders directly in-app via libmpv Metal shaders. Best on screens above 1080p; smaller displays won't show much difference."
            ) {
                SumiSwitch(isOn: $gpuUpscaling)
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Hardware Decoding",
                description: "Apple Silicon VideoToolbox acceleration. Reduces CPU usage and battery drain during playback."
            ) {
                SumiSwitch(isOn: $hardwareDecoding)
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Ambient Glow",
                description: "Lights the black bars in fullscreen with the colours at the picture's edges, like a backlight behind a TV."
            ) {
                SumiSwitch(isOn: $ambientGlow)
            }

            if ambientGlow {
                Divider()
                    .background(SumiTheme.border)

                SettingField(
                    label: "Glow in windowed mode",
                    description: "Also light the bars when the player is a window, not only in fullscreen."
                ) {
                    SumiSwitch(isOn: $ambientGlowWindowed)
                }
            }
        }

        #if os(macOS)
        // Its own card rather than four rows on the end of the playback
        // list: this is the machine's behaviour while an episode runs, not
        // the episode's.
        SettingsCard(
            title: "While watching",
            description: "What this Mac does with itself during playback."
        ) {
            SettingField(
                label: "Dim keyboard backlight",
                description: "Fades the keyboard backlight out after a few idle seconds during playback, and brings it straight back on the first key press, scroll or click."
            ) {
                SumiSwitch(isOn: $keyboardDim)
            }

            if keyboardDim {
                Divider()
                    .background(SumiTheme.border)

                SettingField(
                    label: "When",
                    description: "Night only leaves the keyboard alone during the day."
                ) {
                    SumiSegmentedControl(
                        options: [("always", "Always"), ("night", "Night only")],
                        selection: $keyboardDimMode
                    )
                }

                if keyboardDimMode == "night" {
                    Divider()
                        .background(SumiTheme.border)

                    SettingField(
                        label: "Night Hours",
                        description: "Local time. The window may cross midnight."
                    ) {
                        HStack(spacing: 8) {
                            Text("From")
                                .font(.system(size: 12))
                                .foregroundColor(SumiTheme.muted)
                            SumiDropdown(options: Self.hourOptions, selected: hourBinding($keyboardDimFrom), minWidth: 88)

                            Text("Until")
                                .font(.system(size: 12))
                                .foregroundColor(SumiTheme.muted)
                            SumiDropdown(options: Self.hourOptions, selected: hourBinding($keyboardDimUntil), minWidth: 88)
                        }
                    }
                }
            }
        }
        #endif

        SettingsCard(title: "Sound & haptics") {
            SettingField(
                label: "Interface Sounds",
                description: "Short synthesised blips when a tab changes, the player opens or closes, a back swipe lands and an episode is marked watched. Off by default, because every one of them fires during ordinary navigation."
            ) {
                SumiSwitch(isOn: $interfaceSounds)
            }

            if interfaceSounds {
                Divider()
                    .background(SumiTheme.border)

                SettingField(
                    label: "Sound Volume",
                    description: "Relative to the system output level. These play over a running episode, so the default sits low."
                ) {
                    HStack(spacing: 12) {
                        Slider(value: $interfaceSoundVolume, in: 0...1)
                            .frame(width: 130)
                            .tint(SumiTheme.indigo)

                        Text("\(Int(interfaceSoundVolume * 100))%")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)
                            .frame(width: 38, alignment: .trailing)

                        Button {
                            AppSounds.tabChange.play()
                        } label: {
                            Text("Test")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(SumiTheme.background)
                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                                .overlay(
                                    RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                        .stroke(SumiTheme.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.sumiPressable)
                    }
                }
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Haptic Feedback",
                description: "A trackpad tick when a back swipe crosses the distance that commits it, and when a seek snaps to a chapter or skip boundary. A Mac without a Force Touch trackpad feels nothing either way."
            ) {
                SumiSwitch(isOn: $haptics)
            }
        }
    }
    }
}

/// Everything Anicat tells something outside itself.
///
/// New-episode alerts sat in General and Discord presence on the end of the
/// playback list, two tabs apart, though they answer the same question.
private struct SharingTabSection: View {
    // `SystemNotifications` owns the reader and the default; `@AppStorage`
    // needs a literal here, so the two spellings and the two defaults must
    // agree.
    @AppStorage("anicat_notify_new_episodes") private var notifyNewEpisodes: Bool = true
    // Same literal-key constraint. `AppModel` owns the reader and default.
    @AppStorage("anicat_discord_presence") private var discordPresence: Bool = true
    // Read once into state rather than off `UserDefaults` in the body: the
    // paired list is written by `RemoteHost` from a socket callback, which
    // no `@AppStorage` array binding observes.
    @State private var pairedCount = RemoteHost.pairedDevices().count

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        SettingsCard(title: "Notifications") {
            SettingField(
                label: "New Episode Alerts",
                description: "A local notification when an episode of something you are watching airs. Each episode is announced once, whether or not the app was running when it aired."
            ) {
                SumiSwitch(isOn: $notifyNewEpisodes)
            }
        }

        SettingsCard(title: "Presence") {
            SettingField(
                label: "Discord Rich Presence",
                description: "Show the title, episode and position you are watching on your Discord profile. Has no effect when Discord is not running."
            ) {
                SumiSwitch(isOn: $discordPresence)
            }
        }

        SettingsCard(title: "Devices") {
            SettingField(
                label: "Paired iPhones",
                badge: RemoteHost.shared.attachedRemoteName.map { "\($0) connected" },
                description: pairedCount == 0
                    ? "Anicat on an iPhone on this Wi-Fi can control playback here. The first time one asks, this Mac asks you first."
                    : "\(pairedCount) iPhone\(pairedCount == 1 ? "" : "s") may control playback on this Mac. Forgetting them means being asked again next time."
            ) {
                Button("Forget All") {
                    RemoteHost.shared.unpairAll()
                    pairedCount = 0
                }
                .disabled(pairedCount == 0)
            }
        }
    }
    .onAppear { pairedCount = RemoteHost.pairedDevices().count }
    }
}

private struct AccountTabSection: View {
    let isSignedIn: Bool
    let username: String?
    let avatarUrl: String?
    let onSaveToken: (String) -> Void
    let onDisconnectAniList: () -> Void

    @State private var anilistTokenInput: String = ""
    @State private var disconnectConfirming: Bool = false
    /// A viewer's own TMDB key, which wins over the one the app carries.
    /// `TmdbCredential` is the reader; `@AppStorage` needs a literal here, so
    /// the two spellings have to agree.
    @AppStorage("anicat_tmdb_key") private var tmdbKeyInput: String = ""
    /// `AppModel.offlineCapDefaultsKey`; `@AppStorage` needs a literal, so
    /// the two spellings and the two defaults have to agree.

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        SettingsCard(title: "AniList") {
            if isSignedIn {
                // Profile Header with Avatar & Disconnect
                HStack(spacing: 16) {
                    // Avatar
                    AsyncImage(url: avatarUrl.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color(hex: "#161310")
                                Image(systemName: "person.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(username ?? "AniList User")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(SumiTheme.successLight)
                                .frame(width: 7, height: 7)

                            Text("Connected to AniList")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SumiTheme.successLight)
                        }
                    }

                    Spacer()

                    Button {
                        if disconnectConfirming {
                            onDisconnectAniList()
                            disconnectConfirming = false
                        } else {
                            disconnectConfirming = true
                        }
                    } label: {
                        Text(disconnectConfirming ? "Are you sure? Click again" : "Disconnect")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(SumiTheme.dangerLight)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(SumiTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(disconnectConfirming ? SumiTheme.danger : SumiTheme.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                    .animation(.snappy, value: disconnectConfirming)
                }
                .padding(14)
                .background(Color.white.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )

                Divider()
                    .background(SumiTheme.border)

                // Status
                SettingField(
                    label: "Status",
                    description: "AniList account connection status."
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(SumiTheme.successLight)
                            .frame(width: 8, height: 8)

                        Text("Connected")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.successLight)
                    }
                }

                Divider()
                    .background(SumiTheme.border)

                // API Token
                SettingField(
                    label: "API Token",
                    description: "Your authorization token. Keep this private."
                ) {
                    Text("••••••••••••••••••••••••••••••••")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(SumiTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(SumiTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                }
            } else {
                // Not signed in: Login
                SettingField(
                    label: "Login",
                    description: "Authorize Anicat to access your AniList account."
                ) {
                    Button {
                        // Must match the client id the web build registers
                        // in web/src-tauri/src/commands/auth.rs — this one
                        // was wrong (20822 belongs to a third-party app,
                        // "Airin," not this one) and sent users through
                        // someone else's OAuth client instead of Anicat's own.
                        if let url = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token") {
                            Platform.openExternal(url)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Connect AniList")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(SumiTheme.indigo)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(SumiTheme.indigo.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(SumiTheme.indigo.opacity(0.30), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                }

                Divider()
                    .background(SumiTheme.border)

                // API Token Input
                SettingField(
                    label: "API Token",
                    description: "After authorizing, paste the full URL you were redirected to (or just the token)."
                ) {
                    HStack(spacing: 8) {
                        SecureField("Paste redirect URL or token...", text: $anilistTokenInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground)

                        Button {
                            let trimmed = anilistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                onSaveToken(trimmed)
                                anilistTokenInput = ""
                            }
                        } label: {
                            Text("Save & Connect")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(hex: "#161310"))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(SumiTheme.indigo)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .disabled(anilistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(anilistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SumiTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                    .frame(maxWidth: 340)
                }
            }

            // Cinema mode reads TMDB with a key the app carries, so this is
            // an override and not a requirement -- the field says so, because
            // an empty credential box otherwise reads as a thing to go and
            // fill in before films will work. Takes effect on the next
            // launch: the engine is handed its key when it is constructed.
            SettingsCard(title: "Cinema (TMDB)") {
                SettingField(
                    label: "Your own TMDB key",
                    description: "Optional. Films and series already work without one. Paste a v3 key or a v4 read token to send requests on your own account instead. It takes effect as you type it."
                ) {
                    SecureField("Leave empty to use the built-in key", text: $tmdbKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.foreground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SumiTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                        .frame(maxWidth: 340)
                        // The engine holds the key in memory, so a paste has
                        // to be handed over; before this it reached nothing
                        // until the next launch and cinema mode stayed
                        // hidden with the key sitting right there.
                        .onChange(of: tmdbKeyInput) { _, _ in AppModel.shared?.applyTmdbKey() }
                }

                // Required by TMDB's API terms wherever their data is used,
                // not a courtesy line: the mark and the wording are both
                // theirs. See `TMDBAttribution`.
                TMDBAttribution()
                    .padding(.top, 4)
            }
        }
    }
}

}

private struct MaintenanceTabSection: View {
    static var buildDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let commit = info["AnicatCommit"] as? String
        let built = info["AnicatBuiltAt"] as? String
        var parts = [version]
        if let commit { parts.append(commit) }
        if let built { parts.append("built \(built)") }
        return parts.joined(separator: " · ")
    }

    /// Nil while the first read is in flight, which is a different thing
    /// from an empty cache and must not read as "0 bytes".
    private var cacheLabel: String {
        guard let cacheBytes else { return "Checking…" }
        return ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file)
    }

    let isSignedIn: Bool
    let username: String?
    let onClearRegistry: () async -> Bool
    let onResetOnboarding: () -> Void
    @Binding var copyFeedback: String?

    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_offline_cap_gb") private var offlineCapGb: Int = 2
    @State private var cacheBytes: UInt64?
    /// Nil until a check has run; "Up to date" afterwards. A blank row would
    /// leave the button looking like it had done nothing.
    @State private var updateResult: String?
    @State private var isPurging = false
    @State private var registryState: SettingsView.MaintenanceActionState = .idle
    @State private var onboardingResetState: SettingsView.MaintenanceActionState = .idle

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        // Storage, which had no home at all: the offline-manga cap was filed
        // under Account because the engine happens to own both, and the
        // torrent stream cache -- easily the largest thing the app writes,
        // gigabytes of it -- was not shown anywhere on macOS.
        SettingsCard(
            title: "Storage",
            description: "What Anicat keeps on this Mac, and how much of it."
        ) {
            SettingField(
                label: "Keep at most",
                description: "Downloaded chapters above this are removed, least recently read first. The chapter open in the reader is never removed."
            ) {
                Picker("", selection: $offlineCapGb) {
                    Text("1 GB").tag(1)
                    Text("2 GB").tag(2)
                    Text("5 GB").tag(5)
                    Text("10 GB").tag(10)
                    Text("No limit").tag(0)
                }
                .frame(maxWidth: 140)
                .font(.system(size: 12))
            }
            // The engine holds the cap in memory, so a change has to be
            // handed over rather than waiting for the next launch.
            .onChange(of: offlineCapGb) { _, _ in AppModel.shared?.applyOfflineLimit() }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Streamed video",
                description: "Episodes are streamed from a torrent and the pieces stay on disk so a rewatch or a seek backwards costs nothing. Emptying it frees the space; anything still playing is re-fetched."
            ) {
                HStack(spacing: 12) {
                    Text(cacheLabel)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)

                    Button(isPurging ? "Emptying…" : "Empty") {
                        isPurging = true
                        Task {
                            await AppModel.shared?.purgeStreamCache()
                            cacheBytes = await AppModel.shared?.streamCacheBytes()
                            isPurging = false
                        }
                    }
                    .disabled(isPurging || (cacheBytes ?? 0) == 0)
                }
            }
        }
        .task { cacheBytes = await AppModel.shared?.streamCacheBytes() }

        // Updates Card
        SettingsCard(title: "Updates", description: "Keep the app up to date.") {
            HStack {
                Text("Current version:")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)

                // Read from the bundle, not typed here: the string said 1.0.0
                // for months after the version moved on, and the commit is
                // what tells two same-version installs apart.
                Text(Self.buildDescription)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(SumiTheme.foreground)
                    .textSelection(.enabled)
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Check for updates",
                description: "Asks GitHub for the latest published release. Anicat does not update itself: the button opens the release page so you can replace the app yourself."
            ) {
                HStack(spacing: 10) {
                    if let update = AppModel.shared?.availableUpdate {
                        Text("\(update.version) available")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(SumiTheme.indigo)
                        Button("Open release") { Platform.openExternal(update.pageURL) }
                    } else {
                        if let checked = updateResult {
                            Text(checked)
                                .font(.system(size: 12))
                                .foregroundColor(SumiTheme.muted)
                        }
                        Button(AppModel.shared?.isCheckingForUpdate == true ? "Checking…" : "Check now") {
                            Task {
                                await AppModel.shared?.checkForUpdates(force: true)
                                updateResult = AppModel.shared?.availableUpdate == nil
                                    ? "Up to date"
                                    : nil
                            }
                        }
                        .disabled(AppModel.shared?.isCheckingForUpdate == true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }

        SettingsCard(title: "Licenses", description: "Anicat is free software under the GPL, version 3.") {
            SettingField(
                label: "Acknowledgements",
                description: "The licenses of the libraries, fonts and shaders this app is built with, and where their source is."
            ) {
                AcknowledgementsButton {
                    Text("View")
                }
            }
        }

        // Logs & Debugging Card
        SettingsCard(title: "Logs & Debugging") {
            Button {
                let report = """
                Anicat Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Platform: \(Platform.osName) \(ProcessInfo.processInfo.operatingSystemVersionString)
                Architecture: arm64
                Signed In: \(isSignedIn)
                AniList Viewer: \(username ?? "None")
                Anime4K Upscaling: \(gpuUpscaling ? "Enabled" : "Disabled")
                Timestamp: \(Date())
                """
                Platform.copyToPasteboard(report)
                withAnimation(.snappy) {
                    copyFeedback = "Debug report copied to clipboard!"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.snappy) {
                        copyFeedback = nil
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                    Text("Copy Debug Report")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(SumiTheme.foreground.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)

            #if os(macOS)
            // The file, not its contents: a log is attached to a report,
            // not read in a settings pane, and Finder is the way to attach.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 13))
                    Text("Reveal Log File")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(SumiTheme.foreground.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            #endif

            // Environment Snapshot. No live log stream is wired up in the
            // native build — this used to be five hardcoded strings
            // dressed up as a log window; only the sign-in line was ever
            // real. Better to show the handful of values that ARE real
            // than fabricate the rest.
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed in: \(isSignedIn ? "yes" : "no")")
                Text("Anime4K upscaling: \(gpuUpscaling ? "enabled" : "disabled")")
                Text("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                Text("Log: \(AppLog.fileURL.path)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(SumiTheme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }

        // System Maintenance Card
        SettingsCard(
            title: "System Maintenance",
            description: "Irreversible system actions."
        ) {
            // Clear Local Registry
            Button {
                if registryState == .confirming {
                    registryState = .working
                    Task {
                        let succeeded = await onClearRegistry()
                        await MainActor.run {
                            registryState = succeeded ? .done : .idle
                        }
                    }
                } else if registryState == .idle {
                    registryState = .confirming
                }
            } label: {
                Text(
                    registryState == .working
                        ? "Wiping Registry..."
                        : registryState == .done
                            ? "Registry Wiped"
                            : registryState == .confirming
                                ? "Are you sure? Click again to wipe"
                                : "Clear Local Registry"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(registryState == .done ? SumiTheme.successLight : SumiTheme.dangerLight)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    registryState == .confirming
                        ? SumiTheme.danger.opacity(0.18)
                        : registryState == .done
                            ? SumiTheme.success.opacity(0.18)
                            : Color.white.opacity(0.03)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            registryState == .confirming
                                ? SumiTheme.danger.opacity(0.40)
                                : registryState == .done
                                    ? SumiTheme.success.opacity(0.40)
                                    : SumiTheme.danger.opacity(0.20),
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .animation(.snappy, value: registryState)
            .disabled(registryState == .working || registryState == .done)

            // Reset Onboarding Setup
            Button {
                if onboardingResetState == .confirming {
                    UserDefaults.standard.removeObject(forKey: "anicat_onboarding_seen")
                    onboardingResetState = .done
                    onResetOnboarding()
                } else if onboardingResetState == .idle {
                    onboardingResetState = .confirming
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text(
                        onboardingResetState == .done
                            ? "Onboarding Reset"
                            : onboardingResetState == .confirming
                                ? "Are you sure? Click again to Reset"
                                : "Reset Onboarding Setup"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(onboardingResetState == .done ? SumiTheme.successLight : SumiTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    onboardingResetState == .confirming
                        ? SumiTheme.danger.opacity(0.15)
                        : Color.white.opacity(0.02)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            onboardingResetState == .confirming
                                ? SumiTheme.danger.opacity(0.35)
                                : SumiTheme.border,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .animation(.snappy, value: onboardingResetState)
            .disabled(onboardingResetState == .done)
        }
    }
}
}

// MARK: - Reusable Settings Components

private struct SettingsCard<Content: View>: View {
    let title: String
    var badge: String? = nil
    var description: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 11).smallCaps())
                            .foregroundColor(SumiTheme.muted)
                    }
                }

                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.02))

            Rectangle()
                .fill(SumiTheme.border)
                .frame(height: 1)

            // Body
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(20)
        }
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }
}

private struct SettingField<Trailing: View>: View {
    let label: String
    var badge: String? = nil
    var description: String? = nil
    var isStacked: Bool = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if isStacked {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 11).smallCaps())
                                .foregroundColor(SumiTheme.muted)
                        }
                    }

                    if let description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                trailing()
            }
            .padding(.vertical, 2)
        } else {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 11).smallCaps())
                                .foregroundColor(SumiTheme.muted)
                        }
                    }

                    if let description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 16)

                trailing()
            }
            .padding(.vertical, 2)
        }
    }
}

/// The theme row: one swatch per skin, drawn in that skin's own colours.
///
/// Reads `ThemeStore.shared` rather than keeping `@AppStorage` copies of its
/// own. The store already writes both keys, and a second writer for one
/// setting is how a picker ends up showing a theme the app is not using.
private struct ThemePicker: View {
    @State private var store = ThemeStore.shared

    // Three swatches fit a row; the grid is kept from when the flat list had
    // six, so a fourth skin needs no revisit. `maximum` is pinned to the
    // swatch width on purpose: left open it defaults to `.infinity`, the grid
    // divides the whole pane between the columns it chose, and each 72pt
    // swatch floats in the middle of an oversized cell.
    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 72), spacing: 12, alignment: .topLeading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(SumiSkin.allCases) { skin in
                let isSelected = store.skin == skin
                Button {
                    guard !isSelected else { return }
                    SumiHaptics.selection()
                    store.select(skin)
                } label: {
                    VStack(spacing: 7) {
                        ThemeSwatch(
                            palette: store.previewPalette(for: skin),
                            isSelected: isSelected
                        )

                        Text(skin.displayName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? SumiTheme.foreground : SumiTheme.muted)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(skin.caption)
            }
        }
    }
}

/// A palette in miniature: its ground, one card on it, its accent. Drawn from
/// the palette handed in rather than from `SumiTheme`, which is the whole
/// point — the OLED swatch has to look like OLED while Paper is in force.
private struct ThemeSwatch: View {
    let palette: SumiPalette
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.card)
                    .frame(width: 44, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(palette.border, lineWidth: 1)
                    )

                HStack(spacing: 4) {
                    Capsule()
                        .fill(palette.indigo)
                        .frame(width: 20, height: 5)

                    Capsule()
                        .fill(palette.muted)
                        .frame(width: 12, height: 5)
                }
            }
            .padding(9)
        }
        .frame(width: 72, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? SumiTheme.indigo : SumiTheme.border, lineWidth: isSelected ? 2 : 1)
        )
    }
}

private struct SumiSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(isOn ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.20))
                    .frame(width: 38, height: 22)

                Circle()
                    .fill(SumiTheme.foreground)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.sumiPressable)
    }
}

private struct SumiDropdown: View {
    let options: [String]
    @Binding var selected: String
    var minWidth: CGFloat = 160

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button {
                    selected = opt
                } label: {
                    HStack {
                        Text(opt)
                        if opt == selected {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selected)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SumiTheme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minWidth: minWidth)
            .background(SumiTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .sumiMenuPressable()
        }
        .menuStyle(.borderlessButton)
    }
}
