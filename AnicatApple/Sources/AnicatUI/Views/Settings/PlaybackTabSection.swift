import SwiftUI

/// Playback, split by what each control actually affects.
///
/// This was one "Playback" card holding eleven switches across four
/// unrelated concerns -- what plays, what gets skipped, how the picture is
/// drawn, and what the laptop's keyboard does -- with Discord presence on
/// the end of it. Nothing was findable because nothing was grouped.
struct PlaybackTabSection: View {
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
    // `FeedbackDefaults` owns the reader and the default; the literal here
    // and the one there must agree.
    @AppStorage("anicat_haptics") private var haptics: Bool = true
    // `PlayerController.subtitleScaleKey` and `SubtitleStyle.key`; the phone
    // has had the size since its settings screen was built, the Mac had
    // neither.
    @AppStorage(PlayerController.subtitleScaleKey) private var subtitleScale: Double = 1.0
    @AppStorage(SubtitleStyle.key) private var subtitleStyle: String = SubtitleStyle.release.rawValue

    private static let subtitleSizes: [(key: String, label: String)] = [
        ("0.8", "Small"), ("1.0", "Normal"), ("1.25", "Large"), ("1.5", "Huge"),
    ]

    /// The segmented control speaks strings; the setting is the `Double`
    /// mpv takes. A stored value between the four steps shows as Normal
    /// rather than as nothing selected.
    private var subtitleSizeBinding: Binding<String> {
        Binding(
            get: {
                Self.subtitleSizes.first { Double($0.key) == subtitleScale }?.key ?? "1.0"
            },
            set: { key in
                guard let scale = Double(key) else { return }
                subtitleScale = scale
                AppModel.shared?.playerController.onSetSubtitleScale?(scale)
            }
        )
    }

    /// The tiles speak `SubtitleStyle`; the setting stores the case name.
    private var subtitleStyleBinding: Binding<SubtitleStyle> {
        Binding(
            get: { SubtitleStyle(rawValue: subtitleStyle) ?? .release },
            set: { style in
                subtitleStyle = style.rawValue
                AppModel.shared?.playerController.onSetSubtitleStyle?(style)
            }
        )
    }

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
    VStack(alignment: .leading, spacing: 28) {
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
                    selected: $subDub
                )
            }

            SettingField(
                label: "Auto-skip intros",
                description: "Automatically skip openings and endings using AniSkip. The video player also displays an on-screen skip button when an intro or outro is detected."
            ) {
                SumiSwitch(isOn: $autoSkipIntro)
            }

            SettingField(
                label: "Play the next episode",
                description: "Starts the next episode as the current one ends. The player's own button toggles this too."
            ) {
                SumiSwitch(isOn: $autoPlayNext)
            }

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
                label: "GPU upscaling",
                description: "Anime4K — real-time neural upscaling that sharpens lines and adds depth with minimal battery impact. Renders directly in-app via libmpv Metal shaders. Best on screens above 1080p; smaller displays won't show much difference."
            ) {
                SumiSwitch(isOn: $gpuUpscaling)
            }

            SettingField(
                label: "Hardware decoding",
                description: "Apple Silicon VideoToolbox acceleration. Reduces CPU usage and battery drain during playback."
            ) {
                SumiSwitch(isOn: $hardwareDecoding)
            }

            SettingField(
                label: "Ambient glow",
                description: "Lights the black bars in fullscreen with the colours at the picture's edges, like a backlight behind a TV."
            ) {
                SumiSwitch(isOn: $ambientGlow)
            }

            if ambientGlow {
                SettingField(
                    label: "Glow in windowed mode",
                    description: "Also light the bars when the player is a window, not only in fullscreen."
                ) {
                    SumiSwitch(isOn: $ambientGlowWindowed)
                }
            }
        }

        SettingsCard(
            title: "Subtitles",
            description: "Applied straight away, including to an episode that is playing."
        ) {
            SettingField(
                label: "Size",
                description: "Scales every subtitle, styled releases included."
            ) {
                SumiSegmentedControl(options: Self.subtitleSizes, selection: subtitleSizeBinding)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Style")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                // The chosen look, at the chosen size, over a stand-in frame
                // with a typeset sign in the corner that does not change:
                // the note below promises exactly that.
                SubtitleScene(
                    style: subtitleStyleBinding.wrappedValue,
                    scale: subtitleScale
                )
                .frame(maxWidth: 520)

                SubtitleStyleTiles(selection: subtitleStyleBinding)
                    .frame(maxWidth: 620)

                Text(subtitleStyleBinding.wrappedValue.summary
                    + (subtitleStyleBinding.wrappedValue == .release
                        ? ""
                        : " Only the dialogue changes: signs, song lyrics and on-screen text keep the look the release gave them."))
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
                    SettingField(
                        label: "Night hours",
                        description: "Local time. The window may cross midnight."
                    ) {
                        HStack(spacing: 8) {
                            Text("From")
                                .font(.system(size: 12))
                                .foregroundColor(SumiTheme.muted)
                            SumiDropdown(options: Self.hourOptions, selected: hourBinding($keyboardDimFrom))

                            Text("Until")
                                .font(.system(size: 12))
                                .foregroundColor(SumiTheme.muted)
                            SumiDropdown(options: Self.hourOptions, selected: hourBinding($keyboardDimUntil))
                        }
                    }
                }
            }
        }
        #endif

        SettingsCard(title: "Haptics") {
            SettingField(
                label: "Haptic feedback",
                description: "A trackpad tick when a back swipe crosses the distance that commits it, and when a seek snaps to a chapter or skip boundary. A Mac without a Force Touch trackpad feels nothing either way."
            ) {
                SumiSwitch(isOn: $haptics)
            }
        }
    }
    }
}
