#if os(macOS)
import SwiftUI

public struct SettingsView: View {
    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case playback = "Playback"
        case reading = "Reading"
        case accounts = "Account"
        case sharing = "Sharing"
        case advanced = "Advanced"

        public var id: String { rawValue }

        public var iconName: String {
            switch self {
            case .general: return "gearshape.fill"
            case .playback: return "play.circle.fill"
            case .reading: return "book.fill"
            case .sharing: return "antenna.radiowaves.left.and.right"
            case .accounts: return "person.crop.circle"
            case .advanced: return "wrench.and.screwdriver.fill"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .general

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
        VStack(spacing: 0) {
            SumiTabBar(
                tabs: SettingsTab.allCases.map { ($0.rawValue, $0.rawValue) },
                selection: Binding(
                    get: { selectedTab.rawValue },
                    set: { selectedTab = SettingsTab(rawValue: $0) ?? .general }
                )
            )
            .frame(maxWidth: .infinity)
            // The 28pt title strip over a full-size content view eats
            // clicks; without the inset the tabs sat under it and the top
            // half of each word did not respond.
            .padding(.top, 30)
            .padding(.bottom, 8)

            SettingsHairline()

            ScrollView(.vertical, showsIndicators: true) {
                // Each pane is its own View struct rather than a computed
                // property inlined here: every AppStorage toggle and
                // confirm-flow @State used to live inside one 1236-line
                // body, so flipping one switch re-evaluated every pane's
                // layout, not just the one showing.
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralTabSection(onOpenShortcuts: onOpenShortcuts)
                    case .playback:
                        PlaybackTabSection()
                    case .reading:
                        ReadingTabSection()
                    case .accounts:
                        AccountTabSection(
                            isSignedIn: isSignedIn,
                            username: username,
                            avatarUrl: avatarUrl,
                            onSaveToken: onSaveToken,
                            onDisconnectAniList: onDisconnectAniList
                        )
                    case .sharing:
                        SharingTabSection()
                    case .advanced:
                        MaintenanceTabSection(
                            isSignedIn: isSignedIn,
                            username: username,
                            onClearRegistry: onClearRegistry,
                            onResetOnboarding: onResetOnboarding
                        )
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
                // The tab bar changes selection inside `withAnimation`, and
                // the old and new panes cross-faded over each other: two sets
                // of rows legible at once for a beat on every switch.
                .animation(nil, value: selectedTab)
                // 720 is the Settings window's width. Uncapped in the content
                // column, label and control sat a full screen apart and the
                // eye lost which switch belonged to which row.
                .frame(maxWidth: 720, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(SumiTheme.background)
    }
}
#endif
