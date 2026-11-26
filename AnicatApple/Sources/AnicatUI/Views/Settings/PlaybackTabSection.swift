#if os(macOS)
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
    // `MpvSurface.Coordinator.audioFilter` owns the reader and the
    // default; the literal here and the one there must agree.
    @AppStorage("anicat_normalize_audio") private var normalizeAudio: Bool = true
    @AppStorage("anicat_autoplay_next") private var autoPlayNext: Bool = true
    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_hardware_decoding") private var hardwareDecoding: Bool = true
    @AppStorage("anicat_frame_interpolation") private var frameInterpolation: Bool = false
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

    /// The toggle speaks strings; the setting is the `Double` mpv takes. A
    /// stored value between the four steps shows as Normal rather than as
    /// nothing selected.
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

    private var currentSubtitleStyle: SubtitleStyle {
        SubtitleStyle(rawValue: subtitleStyle) ?? .release
    }

    private func selectSubtitleStyle(_ style: SubtitleStyle) {
        subtitleStyle = style.rawValue
        AppModel.shared?.playerController.onSetSubtitleStyle?(style)
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
    VStack(alignment: .leading, spacing: 18) {
        SettingsCard(title: "Subtitles") {
            // The chosen look, at the chosen size, over a stand-in frame
            // with a typeset sign in the corner that does not change. The
            // scene is 16:9 and sizes its text to its own height, so it is
            // capped by width: full width it stood 360pt tall and pushed
            // every other row of a 560pt window below the fold.
            SubtitleScene(style: currentSubtitleStyle, scale: subtitleScale)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity)

            SettingField(label: "Size") {
                SumiSegmentedControl(options: Self.subtitleSizes, selection: subtitleSizeBinding)
            }

            SettingField(
                label: "Style",
                description: currentSubtitleStyle == .release
                    ? currentSubtitleStyle.summary
                    : "Only the dialogue changes; signs and song lyrics keep the release's look"
            ) {
                SumiSlashToggle(
                    SubtitleStyle.allCases.map { ($0, $0.label) },
                    selection: currentSubtitleStyle,
                    select: selectSubtitleStyle
                )
            }
        }

        SettingsCard(title: "Watching") {
            SettingField(
                label: "Audio",
                description: "A preference, not a filter: nothing is hidden where no dub exists"
            ) {
                SumiSlashToggle(
                    [("Subtitled", "Japanese"), ("Dubbed", "English when available")],
                    selection: subDub
                ) { subDub = $0 }
            }

            SettingField(
                label: "Skip intros and recaps automatically",
                description: "Uses AniSkip; the player still offers a skip button when this is off"
            ) {
                SumiSwitch(isOn: $autoSkipIntro, label: "Skip intros and recaps automatically")
            }

            SettingField(
                label: "Play the next episode",
                description: "The player's own button toggles this too"
            ) {
                SumiSwitch(isOn: $autoPlayNext, label: "Play the next episode")
            }

            SettingField(
                label: "Next episode card",
                description: "Counts down over the ending; off, the next episode arrives without asking"
            ) {
                SumiSwitch(isOn: $nextUpCard, label: "Next episode card")
            }

            SettingField(
                label: "Normalize audio",
                description: "Evens out quiet dialogue and loud scenes, from the next episode"
            ) {
                SumiSwitch(isOn: $normalizeAudio, label: "Normalize audio")
            }
        }

        SettingsCard(title: "Video") {
            SettingField(
                label: "GPU upscaling",
                description: "Anime4K redraws line art as it scales up; costs GPU, turn off on battery"
            ) {
                SumiSwitch(isOn: $gpuUpscaling, label: "GPU upscaling")
            }

            SettingField(
                label: "Hardware decoding",
                description: "VideoToolbox; less CPU and battery during playback"
            ) {
                SumiSwitch(isOn: $hardwareDecoding, label: "Hardware decoding")
            }

            if PlayerController.smoothMotionSupported {
                SettingField(
                    label: "Smooth motion",
                    description: "In-between frames during camera pans; characters and cuts stay as animated"
                ) {
                    SumiSwitch(isOn: $frameInterpolation, label: "Smooth motion")
                }
            }

            SettingField(
                label: "Ambient glow",
                description: "Lights the black bars in fullscreen with the picture's edge colours"
            ) {
                SumiSwitch(isOn: $ambientGlow, label: "Ambient glow")
            }

            if ambientGlow {
                SettingField(label: "Glow in windowed mode") {
                    SumiSwitch(isOn: $ambientGlowWindowed, label: "Glow in windowed mode")
                }
            }
        }

        // This Mac's behaviour while an episode runs, not the episode's.
        SettingsCard(title: "While watching") {
            SettingField(
                label: "Dim keyboard backlight",
                description: "Fades out after a few idle seconds, back on the first key, scroll or click"
            ) {
                SumiSwitch(isOn: $keyboardDim, label: "Dim keyboard backlight")
            }

            if keyboardDim {
                SettingField(label: "When") {
                    SumiSegmentedControl(
                        options: [("always", "Always"), ("night", "Night only")],
                        selection: $keyboardDimMode
                    )
                }

                if keyboardDimMode == "night" {
                    SettingField(label: "Night hours", description: "Local time; may cross midnight") {
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

            SettingField(
                label: "Haptic feedback",
                description: "A trackpad tick when a back swipe commits and a seek snaps to a chapter"
            ) {
                SumiSwitch(isOn: $haptics, label: "Haptic feedback")
            }
        }
    }
    }
}
#endif
