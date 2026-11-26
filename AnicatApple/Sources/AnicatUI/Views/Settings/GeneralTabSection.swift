#if os(macOS)
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
    // The appearance row is gated on `skin.hasLight` and shows
    // `appearance`, so both reads have to be observed ones.
    @State private var themeStore = ThemeStore.shared

    var body: some View {
    VStack(alignment: .leading, spacing: 18) {
        SettingsCard(title: "Skin") {
            ThemePicker()

            // OLED and Night City have no light half, so they get no
            // appearance row at all rather than one whose Light stays dark.
            if themeStore.skin.hasLight {
                SettingField(label: "Light and dark") {
                    SumiSlashToggle(
                        [(AnicatAppearance.light, "Light"), (.dark, "Dark"), (.system, "Match the system")],
                        selection: themeStore.appearance
                    ) { themeStore.select($0) }
                }
            }

            SettingField(
                label: "Poster accent",
                description: "Tint the accent to the cover of the title you have open"
            ) {
                SumiSwitch(isOn: $posterAccentEnabled, label: "Poster accent")
            }

            SettingField(label: "Time format") {
                SumiSlashToggle(
                    [("24-hour", "24-hour"), ("12-hour (AM/PM)", "12-hour")],
                    selection: selectedTimeFormat
                ) { selectedTimeFormat = $0 }
            }
        }

        SettingsCard(title: "Ask and shortcuts") {
            // Ask only appears where Apple Intelligence runs, so this row is
            // the one place that says whether it is on and, if not, why.
            let ask = AskAvailability.summary
            SettingField(label: "Ask Anicat", description: ask.text) {
                Text(ask.isOn ? "On" : "Unavailable")
                    .sumiTabularMono()
                    .foregroundColor(ask.isOn ? SumiTheme.indigo : SumiTheme.muted)
            }

            SettingField(
                label: "Keyboard shortcuts",
                description: "Press ? anywhere in the app to see them"
            ) {
                if let onOpenShortcuts {
                    Button("View shortcuts", action: onOpenShortcuts)
                        .sumiSecondaryButton()
                        .controlSize(.small)
                }
            }
        }
    }
    }
}
#endif
