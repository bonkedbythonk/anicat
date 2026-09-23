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

    // Maintenance card's "Copy debug report" feedback also renders in
    // `headerSection` above the tab rail, so it stays here rather than
    // moving into `MaintenanceTabSection` with the rest of that tab's state.
    @State private var copyFeedback: String? = nil

    enum MaintenanceActionState {
        case idle
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
        .init(label: "Follow system appearance", card: "Appearance", tab: .general),
        .init(label: "Appearance", card: "Appearance", tab: .general),
        .init(label: "Poster accent", card: "Appearance", tab: .general),
        .init(label: "Time format", card: "Appearance", tab: .general),
        .init(label: "Keyboard shortcuts cheat sheet", card: "Keyboard shortcuts", tab: .general),

        .init(label: "Sub/Dub", card: "What plays", tab: .playback),
        .init(label: "Auto-skip intros", card: "What plays", tab: .playback),
        .init(label: "Play the next episode", card: "What plays", tab: .playback),
        .init(label: "Next episode card", card: "What plays", tab: .playback),
        .init(label: "GPU upscaling", card: "Video", tab: .playback),
        .init(label: "Subtitle size", card: "Subtitles", tab: .playback),
        .init(label: "Subtitle style", card: "Subtitles", tab: .playback),
        .init(label: "Hardware decoding", card: "Video", tab: .playback),
        .init(label: "Ambient glow", card: "Video", tab: .playback),
        .init(label: "Glow in windowed mode", card: "Video", tab: .playback),
        .init(label: "Dim keyboard backlight", card: "While watching", tab: .playback),
        .init(label: "Night hours", card: "While watching", tab: .playback),
        .init(label: "Interface sounds", card: "Sound & haptics", tab: .playback),
        .init(label: "Sound volume", card: "Sound & haptics", tab: .playback),
        .init(label: "Haptic feedback", card: "Sound & haptics", tab: .playback),

        .init(label: "New episode alerts", card: "Notifications", tab: .sharing),
        .init(label: "Discord presence", card: "Presence", tab: .sharing),
        .init(label: "Show on profile", card: "Presence", tab: .sharing),
        .init(label: "Paired iPhones", card: "Devices", tab: .sharing),

        .init(label: "AniList account", card: "AniList", tab: .accounts),
        .init(label: "API token", card: "AniList", tab: .accounts),
        .init(label: "Your own TMDB key", card: "Cinema (TMDB)", tab: .accounts),

        .init(label: "Official volumes", card: "Light novel sources", tab: .advanced),
        .init(label: "Offline manga limit", card: "Storage", tab: .advanced),
        .init(label: "Streamed video cache", card: "Storage", tab: .advanced),
        .init(label: "Current version", card: "Updates", tab: .advanced),
        .init(label: "Acknowledgements", card: "Licenses", tab: .advanced),
        .init(label: "Copy debug report", card: "Logs & debugging", tab: .advanced),
        .init(label: "Reveal log file", card: "Logs & debugging", tab: .advanced),
        .init(label: "Clear local registry", card: "System maintenance", tab: .advanced),
        .init(label: "Reset onboarding", card: "System maintenance", tab: .advanced),
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
            Text("Settings")
                .font(.sumiHeading(size: 22, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(SumiTheme.foreground)

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
