import SwiftUI

public struct SettingsView: View {
    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case player = "Player"
        case account = "Account"
        case maintenance = "Maintenance"

        public var id: String { rawValue }

        public var iconName: String {
            switch self {
            case .general: return "gearshape.fill"
            case .player: return "play.circle.fill"
            case .account: return "globe"
            case .maintenance: return "arrow.triangle.2.circlepath"
            }
        }
    }

    // Tab Navigation
    @State private var selectedTab: SettingsTab = .general
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
                        switch selectedTab {
                        case .general:
                            GeneralTabSection()
                        case .player:
                            PlayerTabSection(onOpenShortcuts: onOpenShortcuts)
                        case .account:
                            AccountTabSection(
                                isSignedIn: isSignedIn,
                                username: username,
                                avatarUrl: avatarUrl,
                                onSaveToken: onSaveToken,
                                onDisconnectAniList: onDisconnectAniList
                            )
                        case .maintenance:
                            MaintenanceTabSection(
                                isSignedIn: isSignedIn,
                                username: username,
                                onClearRegistry: onClearRegistry,
                                onResetOnboarding: onResetOnboarding,
                                copyFeedback: $copyFeedback
                            )
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

    // MARK: - Header
    private var headerSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(SumiTheme.foreground)

                Text("Configure playback, appearance, and account")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
            }

            Spacer()

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
    // Only keys something reads belong here. This tab used to carry nine
    // more (a three-way style picker, provider and API dropdowns, a cinema
    // toggle with a TMDB token, an e-reader card) that no code outside
    // Settings ever looked up, so every one of them was a control that
    // changed nothing. They come back with the feature that reads them.
    @AppStorage("anicat_time_format") private var selectedTimeFormat: String = "24-hour"
    @AppStorage("anicat_show_fps_hud") private var showFPSHUD: Bool = false

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        // Appearance Card
        SettingsCard(title: "Appearance") {
            SettingField(
                label: "Theme",
                description: "Ink & Index is the original warm dark skin. Paper is its light counterpart, OLED a true black for panels that switch pixels off. Follow system uses Paper by day and Ink by night.",
                isStacked: true
            ) {
                ThemePicker()
            }

            Divider()
                .background(SumiTheme.border)

            // Time Format
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

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Performance HUD",
                badge: "120Hz Debugger",
                description: "Real-time FPS and frame hitch counter in the top-right corner. Shortcut: ⌘⇧D."
            ) {
                SumiSwitch(isOn: $showFPSHUD)
            }
        }
    }
    }
}

private struct PlayerTabSection: View {
    let onOpenShortcuts: (() -> Void)?

    @AppStorage("anicat_sub_dub") private var subDub: String = "Subtitled"
    @AppStorage("anicat_autoskip") private var autoSkipIntro: Bool = true
    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_hardware_decoding") private var hardwareDecoding: Bool = true
    // Same literal-key constraint as Discord below; `KeyboardDimSchedule`
    // owns the readers and the defaults, and the two must agree.
    @AppStorage("anicat_keyboard_dim") private var keyboardDim: Bool = false
    @AppStorage("anicat_keyboard_dim_mode") private var keyboardDimMode: String = "night"
    @AppStorage("anicat_keyboard_dim_from") private var keyboardDimFrom: Int = 20
    @AppStorage("anicat_keyboard_dim_until") private var keyboardDimUntil: Int = 7
    // Key spelled out rather than `AppModel.discordPresenceKey`:
    // `@AppStorage` needs a literal at the property wrapper. `AppModel` owns
    // the reader and the default; the two must agree.
    @AppStorage("anicat_discord_presence") private var discordPresence: Bool = true

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
        // Playback Card
        SettingsCard(title: "Playback") {
            // Sub/Dub
            SettingField(
                label: "Sub/Dub",
                description: "Preferred audio language for streaming."
            ) {
                SumiDropdown(
                    options: ["Subtitled", "Dubbed"],
                    selected: $subDub,
                    minWidth: 160
                )
            }

            Divider()
                .background(SumiTheme.border)

            // Auto-Skip Intros
            SettingField(
                label: "Auto-Skip Intros",
                description: "Automatically skip openings and endings using AniSkip. The video player also displays an on-screen skip button when an intro or outro is detected."
            ) {
                SumiSwitch(isOn: $autoSkipIntro)
            }

            Divider()
                .background(SumiTheme.border)

            // GPU Upscaling
            SettingField(
                label: "GPU Upscaling",
                description: "Anime4K — real-time neural upscaling that sharpens lines and adds depth with minimal battery impact. Renders directly in-app via libmpv Metal shaders. Best on screens above 1080p; smaller displays won't show much difference."
            ) {
                SumiSwitch(isOn: $gpuUpscaling)
            }

            Divider()
                .background(SumiTheme.border)

            // Hardware Decoding
            SettingField(
                label: "Hardware Decoding",
                description: "Apple Silicon VideoToolbox acceleration. Reduces CPU usage and battery drain during playback."
            ) {
                SumiSwitch(isOn: $hardwareDecoding)
            }

            #if os(macOS)
            Divider()
                .background(SumiTheme.border)

            // Keyboard Backlight
            SettingField(
                label: "Dim keyboard backlight while watching",
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
            #endif

            Divider()
                .background(SumiTheme.border)

            // Discord Rich Presence
            SettingField(
                label: "Discord Rich Presence",
                description: "Show the title, episode and position you are watching on your Discord profile. Has no effect when Discord is not running."
            ) {
                SumiSwitch(isOn: $discordPresence)
            }
        }

        // Keyboard Shortcuts Card
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

private struct AccountTabSection: View {
    let isSignedIn: Bool
    let username: String?
    let avatarUrl: String?
    let onSaveToken: (String) -> Void
    let onDisconnectAniList: () -> Void

    @State private var anilistTokenInput: String = ""
    @State private var disconnectConfirming: Bool = false

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

            // Status Diagnostics Box
            VStack(spacing: 7) {
                diagnosticRow(label: "Token saved", value: isSignedIn ? "yes" : "no", isGood: isSignedIn)
                diagnosticRow(label: "Backend connected", value: "yes", isGood: true)
                diagnosticRow(label: "AniList validated", value: isSignedIn ? "yes" : "no", isGood: isSignedIn)
                if let username, !username.isEmpty {
                    diagnosticRow(label: "Signed in as", value: username, isGood: true, highlightColor: SumiTheme.indigo)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }
    }
}

private func diagnosticRow(label: String, value: String, isGood: Bool, highlightColor: Color? = nil) -> some View {
    HStack {
        Text(label)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(SumiTheme.muted)

        Spacer()

        Text(value)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(highlightColor ?? (isGood ? SumiTheme.successLight : SumiTheme.muted.opacity(0.6)))
    }
}

}

private struct MaintenanceTabSection: View {
    let isSignedIn: Bool
    let username: String?
    let onClearRegistry: () async -> Bool
    let onResetOnboarding: () -> Void
    @Binding var copyFeedback: String?

    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @State private var registryState: SettingsView.MaintenanceActionState = .idle
    @State private var onboardingResetState: SettingsView.MaintenanceActionState = .idle

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        // Updates Card
        SettingsCard(title: "Updates", description: "Keep the app up to date.") {
            HStack {
                Text("Current version:")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)

                Text("1.0.0 (Native Apple Silicon ARM64)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(SumiTheme.foreground)
            }

            // No update mechanism exists in the native build yet — a
            // fake "checking" spinner that always reports up to date is
            // worse than no button, since it reads as a real check.
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                Text("Update checking isn't available yet in the native build.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SumiTheme.muted)
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

        // Logs & Debugging Card
        SettingsCard(title: "Logs & Debugging") {
            Button {
                let report = """
                Anicat Version: 1.0.0 (Native Apple Silicon ARM64)
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

            // Environment Snapshot. No live log stream is wired up in the
            // native build — this used to be five hardcoded strings
            // dressed up as a log window; only the sign-in line was ever
            // real. Better to show the handful of values that ARE real
            // than fabricate the rest.
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed in: \(isSignedIn ? "yes" : "no")")
                Text("Anime4K upscaling: \(gpuUpscaling ? "enabled" : "disabled")")
                Text("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
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

/// The theme row: one swatch per option, drawn in that option's own colours.
///
/// Reads `ThemeStore.shared` rather than keeping an `@AppStorage("anicat_theme")`
/// of its own. The store already writes that key, and a second writer for one
/// setting is how a picker ends up showing a theme the app is not using.
private struct ThemePicker: View {
    @State private var store = ThemeStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(AnicatTheme.allCases) { theme in
                let isSelected = store.theme == theme
                Button {
                    guard !isSelected else { return }
                    SumiHaptics.selection()
                    store.select(theme)
                } label: {
                    VStack(spacing: 7) {
                        ThemeSwatch(
                            palette: theme.previewPalette(systemIsDark: ThemeStore.systemPrefersDark),
                            isSelected: isSelected
                        )

                        Text(theme.displayName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? SumiTheme.foreground : SumiTheme.muted)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(theme.caption)
            }

            Spacer(minLength: 0)
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
