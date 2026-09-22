import SwiftUI

struct GeneralTabSection: View {
    let onOpenShortcuts: (() -> Void)?

    // Only keys something reads belong here. This tab used to carry nine
    // more (a three-way style picker, provider and API dropdowns, a cinema
    // toggle with a TMDB token, an e-reader card) that no code outside
    // Settings ever looked up, so every one of them was a control that
    // changed nothing. They come back with the feature that reads them.
    @AppStorage("anicat_time_format") private var selectedTimeFormat: String = "24-hour"
    @AppStorage("anicat_poster_accent") private var posterAccentEnabled: Bool = true
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
                label: "Poster Accent",
                description: "Tint the accent to the cover of the title you have open. Off keeps the skin's own colour everywhere."
            ) {
                SumiSwitch(isOn: $posterAccentEnabled)
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
