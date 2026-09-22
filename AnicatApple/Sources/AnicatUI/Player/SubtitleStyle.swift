import Foundation

/// A subtitle look the viewer can pick in Settings > Playback.
///
/// Fansub releases ship ASS subtitles that carry their own fonts, colours
/// and, above all, typesetting: signs placed over the shot, song lyrics,
/// on-screen text translated in the style of the original. The obvious way to
/// restyle them, `sub-ass-override=force`, rewrites every style in the file,
/// and signs turn into white dialogue text floating over the scene. So a
/// preset here restyles ASS files through `sub-ass-style-overrides` with a
/// style name in front of each field (libass's `Style.Field=Value`), aimed at
/// the names fansub groups and simulcasts use for dialogue. A style called
/// "Sign", "TS" or "Title" is left exactly as the release made it.
///
/// Plain-text subtitles (SRT, WebVTT) have no styles of their own and take
/// the preset through mpv's `sub-*` options instead.
///
/// Every font named here ships with macOS, so no preset silently falls back
/// to a substitute that looks nothing like its name, and nothing needs
/// bundling. Size is not part of a style: it is `sub-scale`, set separately.
public enum SubtitleStyle: String, CaseIterable, Identifiable, Sendable {
    /// Whatever the release shipped. mpv's own defaults for text subtitles.
    case release
    /// Trebuchet MS, bold, white with a heavy black outline: the look most
    /// people picture for simulcast anime subtitles.
    case simulcast
    /// Clean sans with a thin outline and a soft shadow, the streaming
    /// service look.
    case streaming
    /// Bold yellow with a black outline: the DVD and early fansub look.
    case classicYellow
    /// White on a translucent black box, like television captions. Reads
    /// over any picture.
    case boxed

    public var id: String { rawValue }

    public static let key = "anicat_subtitle_style"

    /// Unset, or a value an older build does not know, reads as `.release`,
    /// which is what every install had before this setting existed.
    public static var current: SubtitleStyle {
        UserDefaults.standard.string(forKey: key).flatMap(SubtitleStyle.init(rawValue:)) ?? .release
    }

    public var label: String {
        switch self {
        case .release: return "Release default"
        case .simulcast: return "Simulcast"
        case .streaming: return "Streaming"
        case .classicYellow: return "Classic yellow"
        case .boxed: return "Boxed"
        }
    }

    public var summary: String {
        switch self {
        case .release: return "Exactly as the release styled them."
        case .simulcast: return "Trebuchet MS, bold white with a heavy black outline."
        case .streaming: return "Clean sans, thin outline and a soft shadow."
        case .classicYellow: return "Bold yellow with a black outline, the DVD-era look."
        case .boxed: return "White on a translucent black box, readable over anything."
        }
    }

    /// The look itself, in one place, so the ASS overrides and the text
    /// options cannot drift apart. Colours are `0xAARRGGBB` with alpha as
    /// opacity (0xFF = solid).
    struct Look {
        let font: String
        let bold: Bool
        let text: UInt32
        let outline: UInt32
        let outlineWidth: Double
        let shadow: UInt32
        let shadowOffset: Double
        /// A box behind the text instead of an outline around it.
        let boxed: Bool
    }

    var look: Look? {
        switch self {
        case .release:
            return nil
        case .simulcast:
            return Look(font: "Trebuchet MS", bold: true, text: 0xFFFFFFFF, outline: 0xFF000000,
                        outlineWidth: 2.6, shadow: 0xA0000000, shadowOffset: 1, boxed: false)
        case .streaming:
            return Look(font: "Helvetica Neue", bold: false, text: 0xFFFFFFFF, outline: 0xFF000000,
                        outlineWidth: 1.2, shadow: 0x90000000, shadowOffset: 1.6, boxed: false)
        case .classicYellow:
            return Look(font: "Arial", bold: true, text: 0xFFFFE62E, outline: 0xFF000000,
                        outlineWidth: 2.2, shadow: 0x80000000, shadowOffset: 1, boxed: false)
        case .boxed:
            return Look(font: "Helvetica Neue", bold: false, text: 0xFFFFFFFF, outline: 0xB0000000,
                        outlineWidth: 5, shadow: 0x00000000, shadowOffset: 0, boxed: true)
        }
    }

    /// The style names fansub groups and simulcast rips give their dialogue.
    /// Anything else (signs, songs, titles, notes) keeps the release's look.
    static let dialogueStyleNames = [
        "Default", "Main", "Dialogue", "Dialog", "Default-alt", "Alt",
        "Italics", "Italic", "Main-italic", "Top", "Main-top", "Default-top",
        "Flashback", "Thoughts", "Overlap", "Narration",
    ]

    /// `sub-ass-style-overrides`, or the empty string for `.release`, which
    /// clears whatever an earlier pick set.
    ///
    /// Font, weight, colours and border style only: no `Outline`, no
    /// `Shadow`. Those two are in the file's own script pixels, and a
    /// release's coordinate space is whatever its group chose: SubsPlease
    /// writes PlayResY 360, a BD group 720 or 1080. The widths here are in
    /// mpv's 720-line units, so written into a 360-line SubsPlease file the
    /// outline came out twice as thick, and with the bold weight Simulcast
    /// read as a size larger than the release's own look (owner: "much
    /// bigger than the standard one"). The group already tuned the width
    /// for its own PlayRes; the preset keeps it.
    var assOverrides: String {
        guard let look else { return "" }
        let fields: [(String, String)] = [
            ("Fontname", look.font),
            ("Bold", look.bold ? "-1" : "0"),
            ("PrimaryColour", Self.assColour(look.text)),
            ("OutlineColour", Self.assColour(look.outline)),
            ("BackColour", Self.assColour(look.shadow)),
            ("BorderStyle", look.boxed ? "3" : "1"),
        ]
        return Self.dialogueStyleNames
            .flatMap { style in fields.map { "\(style).\($0.0)=\($0.1)" } }
            .joined(separator: ",")
    }

    /// mpv's `sub-*` options for plain-text subtitles. `.release` restores
    /// mpv's documented defaults, so switching back undoes a preset without
    /// restarting the player.
    var textOptions: [(String, String)] {
        guard let look else {
            return [
                ("sub-font", "sans-serif"), ("sub-bold", "no"),
                ("sub-color", "#FFFFFFFF"), ("sub-border-color", "#FF000000"),
                ("sub-border-size", "3"), ("sub-shadow-offset", "0"),
                ("sub-shadow-color", "#F0000000"), ("sub-back-color", "#00000000"),
                ("sub-border-style", "outline-and-shadow"),
            ]
        }
        return [
            ("sub-font", look.font), ("sub-bold", look.bold ? "yes" : "no"),
            ("sub-color", Self.mpvColour(look.text)),
            ("sub-border-color", Self.mpvColour(look.outline)),
            ("sub-border-size", Self.number(look.outlineWidth)),
            ("sub-shadow-offset", Self.number(look.shadowOffset)),
            ("sub-shadow-color", Self.mpvColour(look.shadow)),
            ("sub-back-color", look.boxed ? Self.mpvColour(look.outline) : "#00000000"),
            ("sub-border-style", look.boxed ? "opaque-box" : "outline-and-shadow"),
        ]
    }

    /// ASS writes colours as `&HAABBGGRR` with alpha as *transparency*
    /// (0x00 = solid), the reverse of both byte order and alpha sense in
    /// `0xAARRGGBB`.
    static func assColour(_ argb: UInt32) -> String {
        let a = 0xFF - ((argb >> 24) & 0xFF)
        let r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF
        return String(format: "&H%02X%02X%02X%02X", a, b, g, r)
    }

    /// mpv takes `#AARRGGBB` with alpha as opacity.
    static func mpvColour(_ argb: UInt32) -> String {
        String(format: "#%08X", argb)
    }

    /// Trailing zeros off, so a whole number reads "3" and not "3.0".
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
