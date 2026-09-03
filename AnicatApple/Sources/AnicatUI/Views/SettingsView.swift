import SwiftUI

public struct SettingsView: View {
    public enum SettingsTab: String, CaseIterable, Identifiable {
        case account = "Account"
        case player = "Player"
        case general = "General"
        case about = "About"

        public var id: String { rawValue }
    }

    @State private var selectedTab: SettingsTab = .account
    @State private var anilistTokenInput: String = ""
    @State private var defaultAnime4KPreset: Anime4KPreset = .modeAFast
    @State private var autoSkipIntro: Bool = true
    @State private var hardwareDecoding: Bool = true

    public let onSaveToken: (String) -> Void
    public let onDisconnectAniList: () -> Void

    public init(
        onSaveToken: @escaping (String) -> Void = { _ in },
        onDisconnectAniList: @escaping () -> Void = {}
    ) {
        self.onSaveToken = onSaveToken
        self.onDisconnectAniList = onDisconnectAniList
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Settings")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(SumiTheme.foreground)
                    .padding(.horizontal, 28)

                // Tabs
                HStack(spacing: 8) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button(action: { selectedTab = tab }) {
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundColor(selectedTab == tab ? SumiTheme.foreground : SumiTheme.muted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(selectedTab == tab ? SumiTheme.card : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                                .overlay(
                                    RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                        .stroke(selectedTab == tab ? SumiTheme.border : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)

                Divider()
                    .background(SumiTheme.border)
                    .padding(.horizontal, 28)

                // Tab Content
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .account:
                        accountSection
                    case .player:
                        playerSection
                    case .general:
                        generalSection
                    case .about:
                        aboutSection
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.vertical, 24)
        }
        .background(SumiTheme.background)
    }

    // MARK: - Account (AniList OAuth)
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AniList Integration")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                Text("Log into AniList to synchronize your watch history, scores, and Up Next queue across all your devices via iCloud Keychain.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OAUTH TOKEN")
                    .sumiTabularMono(size: 10, weight: .semibold)
                    .foregroundColor(SumiTheme.muted)

                HStack {
                    SecureField("Paste AniList OAuth Token...", text: $anilistTokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.foreground)

                    Button("Save & Connect") {
                        if !anilistTokenInput.isEmpty {
                            onSaveToken(anilistTokenInput)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SumiTheme.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                }
                .padding(10)
                .background(SumiTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Player Settings
    private var playerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Video Engine & Shaders")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                Text("Embedded libmpv with Apple Silicon VideoToolbox and official Anime4K GLSL shaders.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
            }

            // Anime4K Default Preset Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("DEFAULT ANIME4K PRESET")
                    .sumiTabularMono(size: 10, weight: .semibold)
                    .foregroundColor(SumiTheme.muted)

                Picker("Preset", selection: $defaultAnime4KPreset) {
                    ForEach(Anime4KPreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Automatic VideoToolbox Hardware Decoding", isOn: $hardwareDecoding)
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.foreground)

            Toggle("Enable AniSkip Intro/Outro Detection", isOn: $autoSkipIntro)
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.foreground)
        }
    }

    // MARK: - General
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General Preferences")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            Text("Theme: Sumi Ledger (Ink & Washi Paper)")
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.muted)
        }
    }

    // MARK: - About
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AniCat Native for Apple")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            Text("Version 1.0.0 (Native Apple Silicon ARM64)")
                .sumiTabularMono(size: 12)
                .foregroundColor(SumiTheme.indigo)
            Text("Headless Rust engine (librqbit 8.1.1 + UniFFI) · Pure SwiftUI · Embedded Metal libmpv")
                .font(.system(size: 12))
                .foregroundColor(SumiTheme.muted)
        }
    }
}
