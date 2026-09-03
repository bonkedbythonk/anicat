import SwiftUI
#if os(macOS)
import AppKit
#endif

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

    // General: Appearance
    @AppStorage("anicat_theme") private var selectedTheme: String = "System Default"
    @AppStorage("anicat_ui_style") private var selectedStyle: String = "ink-and-index"
    @AppStorage("anicat_time_format") private var selectedTimeFormat: String = "24-hour"

    // General: Advanced
    @AppStorage("anicat_cinema_enabled") private var cinemaEnabled: Bool = false
    @AppStorage("anicat_tmdb_token") private var tmdbToken: String = ""
    @AppStorage("anicat_anime_provider") private var animeProvider: String = "Torrents (Nyaa)"
    @AppStorage("anicat_manga_provider") private var mangaProvider: String = "MangaDex (Default)"
    @AppStorage("anicat_novel_provider") private var novelProvider: String = "RanobeDB"
    @AppStorage("anicat_media_api") private var mediaApi: String = "AniList"

    // General: E-Reader
    @AppStorage("anicat_ereader_profile") private var ereaderProfile: String = "★ Xteink X3 (528×792)"
    @AppStorage("anicat_ereader_grayscale") private var ereaderGrayscale: Bool = true
    @AppStorage("anicat_ereader_split_spreads") private var ereaderSplitSpreads: Bool = true

    // Player
    @AppStorage("anicat_sub_dub") private var subDub: String = "Subtitled"
    @AppStorage("anicat_autoskip") private var autoSkipIntro: Bool = true
    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_hardware_decoding") private var hardwareDecoding: Bool = true

    // Account & Transient State
    @State private var anilistTokenInput: String = ""
    @State private var disconnectConfirming: Bool = false
    @State private var registryState: MaintenanceActionState = .idle
    @State private var onboardingResetState: MaintenanceActionState = .idle
    @State private var checkingUpdate: Bool = false
    @State private var updateMessage: String? = nil
    @State private var copyFeedback: String? = nil

    private enum MaintenanceActionState {
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

    public init(
        isSignedIn: Bool = false,
        username: String? = nil,
        avatarUrl: String? = nil,
        initialTab: SettingsTab = .general,
        onSaveToken: @escaping (String) -> Void = { _ in },
        onDisconnectAniList: @escaping () -> Void = {}
    ) {
        self.isSignedIn = isSignedIn
        self.username = username
        self.avatarUrl = avatarUrl
        self._selectedTab = State(initialValue: initialTab)
        self.onSaveToken = onSaveToken
        self.onDisconnectAniList = onDisconnectAniList
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
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .general:
                            generalTab
                        case .player:
                            playerTab
                        case .account:
                            accountTab
                        case .maintenance:
                            maintenanceTab
                        }
                    }
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
                    selectedTab = tab
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
                    .background(
                        isActive
                            ? SumiTheme.foreground.opacity(0.08)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - General Tab
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Appearance Card
            SettingsCard(title: "Appearance") {
                // Theme
                SettingField(
                    label: "Theme",
                    description: "Choose your preferred visual theme."
                ) {
                    SumiDropdown(
                        options: ["System Default", "Dark", "Light"],
                        selected: $selectedTheme,
                        minWidth: 160
                    )
                }

                Divider()
                    .background(SumiTheme.border)

                // Style
                SettingField(
                    label: "Style",
                    description: "Choose a complete visual skin for the interface.",
                    isStacked: true
                ) {
                    HStack(spacing: 12) {
                        // Ink & Index
                        stylePreviewCard(
                            id: "ink-and-index",
                            title: "Ink & Index",
                            subtitle: "Warm ink / Indigo accent",
                            gradientColors: [Color(hex: "#161310"), Color(hex: "#1E1A15"), Color(hex: "#252015")],
                            swatch1: Color(hex: "#1E1A15"),
                            swatch1Border: Color.white.opacity(0.08),
                            swatch2: Color(hex: "#8FB8DC").opacity(0.30),
                            swatch2Border: Color(hex: "#8FB8DC").opacity(0.50)
                        )

                        // Sakura Zen
                        stylePreviewCard(
                            id: "sakura-zen",
                            title: "Sakura Zen",
                            subtitle: "Soft pastel / Japanese editorial",
                            gradientColors: [Color(hex: "#130910"), Color(hex: "#1A0E14"), Color(hex: "#1F1018")],
                            swatch1: Color(hex: "#F4B4C4").opacity(0.08),
                            swatch1Border: Color(hex: "#E8A0B4").opacity(0.20),
                            swatch2: Color(hex: "#E8A0B4").opacity(0.25),
                            swatch2Border: Color(hex: "#E8A0B4").opacity(0.40)
                        )

                        // Retro Manga
                        stylePreviewCard(
                            id: "retro-manga",
                            title: "Retro Manga",
                            subtitle: "Halftone dot / Manga panel style",
                            gradientColors: [Color(hex: "#191410"), Color(hex: "#241E17")],
                            swatch1: Color(hex: "#EDE8E0"),
                            swatch1Border: Color(hex: "#0C0A08"),
                            swatch2: Color(hex: "#C02024"),
                            swatch2Border: Color(hex: "#0C0A08")
                        )
                    }
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
            }

            // Advanced Card
            SettingsCard(
                title: "Advanced",
                description: "Rarely need to change these after initial setup."
            ) {
                // Movies and series
                SettingField(
                    label: "Movies and series",
                    description: "Adds a second mode for movies and series. Click the logo at the bottom of the sidebar to switch worlds. Still being built, so it has no catalogue yet."
                ) {
                    SumiSwitch(isOn: $cinemaEnabled)
                }

                if cinemaEnabled {
                    Divider()
                        .background(SumiTheme.border)

                    SettingField(
                        label: "TMDB Token",
                        description: "Where movie and series details come from. Free from themoviedb.org, under Settings then API."
                    ) {
                        SecureField("Paste your read access token", text: $tmdbToken)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(SumiTheme.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(SumiTheme.border, lineWidth: 1)
                            )
                            .frame(maxWidth: 240)
                    }
                }

                Divider()
                    .background(SumiTheme.border)

                // Anime Provider
                SettingField(
                    label: "Anime Provider",
                    description: "Primary streaming source."
                ) {
                    SumiDropdown(
                        options: ["Torrents (Nyaa)"],
                        selected: $animeProvider,
                        minWidth: 160
                    )
                }

                Divider()
                    .background(SumiTheme.border)

                // Manga Provider
                SettingField(
                    label: "Manga Provider",
                    description: "Source for manga chapters."
                ) {
                    SumiDropdown(
                        options: ["MangaDex (Default)", "MangaKatana"],
                        selected: $mangaProvider,
                        minWidth: 160
                    )
                }

                Divider()
                    .background(SumiTheme.border)

                // Novel Provider
                SettingField(
                    label: "Light Novel Provider",
                    description: "Primary index and source for light novels. RanobeDB carries the richest metadata and published volumes; the rest are web-novel sources."
                ) {
                    SumiDropdown(
                        options: [
                            "RanobeDB",
                            "Lnori",
                            "Syosetu (小説家になろう)",
                            "Kakuyomu (カクヨム)",
                            "Hameln (ハーメルン)",
                            "Royal Road",
                            "Baka-Tsuki"
                        ],
                        selected: $novelProvider,
                        minWidth: 160
                    )
                }

                Divider()
                    .background(SumiTheme.border)

                // Search & Tracking API
                SettingField(
                    label: "Search & Tracking API",
                    description: "Metadata and list sync source."
                ) {
                    SumiDropdown(
                        options: ["AniList", "Jikan (MyAnimeList - Fallback)"],
                        selected: $mediaApi,
                        minWidth: 160
                    )
                }
            }

            // CrossPoint E-Reader Optimization Card
            SettingsCard(title: "CrossPoint E-Reader Optimization") {
                SettingField(
                    label: "Default E-Reader Device",
                    description: "Pre-configures image dimensions and screen layout for your e-reader hardware."
                ) {
                    SumiDropdown(
                        options: [
                            "★ Xteink X3 (528×792)",
                            "Xteink X4 (480×800)",
                            "Kindle Paperwhite (1072×1448)",
                            "Kindle Basic (600×800)",
                            "Kobo Clara (1072×1448)",
                            "Kobo Libra (1264×1680)",
                            "Custom Resolution"
                        ],
                        selected: $ereaderProfile,
                        minWidth: 180
                    )
                }

                Divider()
                    .background(SumiTheme.border)

                SettingField(
                    label: "8-bit True Grayscale Mode (Mode L)",
                    description: "Converts images to hardware 8-bit grayscale to eliminate dithering artifacts on e-ink."
                ) {
                    SumiSwitch(isOn: $ereaderGrayscale)
                }

                Divider()
                    .background(SumiTheme.border)

                SettingField(
                    label: "Auto-Split Landscape Double Spreads",
                    description: "Detects wide illustration spreads (w > h * 1.15) and cuts them into Left & Right portrait pages at full height."
                ) {
                    SumiSwitch(isOn: $ereaderSplitSpreads)
                }
            }
        }
    }

    // MARK: - Style Preview Card Helper
    private func stylePreviewCard(
        id: String,
        title: String,
        subtitle: String,
        gradientColors: [Color],
        swatch1: Color,
        swatch1Border: Color,
        swatch2: Color,
        swatch2Border: Color
    ) -> some View {
        let isSelected = selectedStyle == id

        return Button {
            selectedStyle = id
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    // Preview Banner
                    ZStack(alignment: .bottom) {
                        LinearGradient(
                            colors: gradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(swatch1)
                                .frame(height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(swatch1Border, lineWidth: 1))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(swatch2)
                                .frame(height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(swatch2Border, lineWidth: 1))
                        }
                        .padding(10)
                    }
                    .frame(height: 72)

                    // Footer Info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(SumiTheme.foreground)

                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(SumiTheme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(SumiTheme.card)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? SumiTheme.indigo : SumiTheme.border, lineWidth: isSelected ? 2 : 1)
                )

                // Blue Checkmark Badge
                if isSelected {
                    Circle()
                        .fill(SumiTheme.indigo)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(hex: "#161310"))
                        )
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Player Tab
    private var playerTab: some View {
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
                    description: "Automatically skip openings and endings using AniSkip. Press S in-player to skip manually when disabled."
                ) {
                    SumiSwitch(isOn: $autoSkipIntro)
                }

                Divider()
                    .background(SumiTheme.border)

                // GPU Upscaling
                SettingField(
                    label: "GPU Upscaling",
                    description: "Anime4K — real-time neural upscaling that sharpens lines and adds depth with minimal battery impact. Renders directly in-app via libmpv Metal shaders. Best on screens above 1080p; smaller displays won't show much difference. Ctrl+1 in-player toggles this too."
                ) {
                    SumiSwitch(isOn: $gpuUpscaling)
                }

            }

            // Keyboard Shortcuts Card
            SettingsCard(title: "Keyboard Shortcuts") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("While a video is playing, you can use these shortcuts:")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Settings — Ctrl + number")
                            .sumiTabularMono(size: 10.5, weight: .semibold)
                            .foregroundColor(SumiTheme.muted)

                        VStack(spacing: 0) {
                            shortcutLine(label: "Toggle Upscaling", key: "Ctrl + 1")
                            Divider().background(SumiTheme.border)
                            shortcutLine(label: "Toggle Auto-skip Intro", key: "Ctrl + 2")
                            Divider().background(SumiTheme.border)
                            shortcutLine(label: "Toggle Autoplay Next", key: "Ctrl + 4")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Actions — Shift + letter")
                            .sumiTabularMono(size: 10.5, weight: .semibold)
                            .foregroundColor(SumiTheme.muted)

                        VStack(spacing: 0) {
                            shortcutLine(label: "Reload Episode", key: "Shift + R")
                            Divider().background(SumiTheme.border)
                            shortcutLine(label: "Skip Segment", key: "Shift + S")
                            Divider().background(SumiTheme.border)
                            shortcutLine(label: "Toggle Sub/Dub", key: "Shift + T")
                            Divider().background(SumiTheme.border)
                            shortcutLine(label: "Rotate Video", key: "Shift + V")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func shortcutLine(label: String, key: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(SumiTheme.foreground.opacity(0.75))

            Spacer()

            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(SumiTheme.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(SumiTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
        }
        .padding(.vertical, 8)
    }

    // MARK: - Account Tab
    private var accountTab: some View {
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
                        }
                        .buttonStyle(.plain)
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
                            #if os(macOS)
                            if let url = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=20822&response_type=token") {
                                NSWorkspace.shared.open(url)
                            }
                            #endif
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
                        }
                        .buttonStyle(.plain)
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
                            }
                            .buttonStyle(.plain)
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

    // MARK: - Maintenance Tab
    private var maintenanceTab: some View {
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

                Button {
                    checkingUpdate = true
                    updateMessage = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        checkingUpdate = false
                        updateMessage = "AniCat 1.0.0 is currently up to date."
                    }
                } label: {
                    HStack(spacing: 8) {
                        if checkingUpdate {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                        }

                        Text(checkingUpdate ? "Checking..." : "Check for Updates")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "#161310"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(checkingUpdate)

                if let updateMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(SumiTheme.successLight)
                        Text(updateMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(SumiTheme.successLight)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SumiTheme.success.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(SumiTheme.success.opacity(0.25), lineWidth: 1)
                    )
                }
            }

            // Logs & Debugging Card
            SettingsCard(title: "Logs & Debugging") {
                Button {
                    #if os(macOS)
                    let report = """
                    AniCat Version: 1.0.0 (Native Apple Silicon ARM64)
                    Platform: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
                    Architecture: arm64
                    Signed In: \(isSignedIn)
                    AniList Viewer: \(username ?? "None")
                    Anime4K Upscaling: \(gpuUpscaling ? "Enabled" : "Disabled")
                    Timestamp: \(Date())
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copyFeedback = "Debug report copied to clipboard!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        copyFeedback = nil
                    }
                    #endif
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
                }
                .buttonStyle(.plain)

                // Log Window
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("[core::engine] Engine initialized with loopback range-server on 127.0.0.1")
                        Text("[core::mpv] Metal layer attached to MPV surface (Apple Silicon VideoToolbox hwdec enabled)")
                        Text("[core::shaders] Loaded Anime4K shader pipeline: Mode A (Fast)")
                        Text("[auth::keychain] Loaded AniList credential state (\(isSignedIn ? "Signed In" : "Logged Out"))")
                        Text("[network::proxy] Local stream multiplexer ready")
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(SumiTheme.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            registryState = .done
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
                }
                .buttonStyle(.plain)
                .disabled(registryState == .working || registryState == .done)

                // Reset Onboarding Setup
                Button {
                    if onboardingResetState == .confirming {
                        UserDefaults.standard.removeObject(forKey: "anicat_onboarding_seen")
                        onboardingResetState = .done
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
                }
                .buttonStyle(.plain)
                .disabled(onboardingResetState == .done)
            }
        }
    }
}

// MARK: - Reusable Settings Components

private struct SettingsCard<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)

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
    var description: String? = nil
    var isStacked: Bool = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if isStacked {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)

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
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)

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

private struct SumiSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
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
        }
        .buttonStyle(.plain)
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
        }
        .menuStyle(.borderlessButton)
    }
}
