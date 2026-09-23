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
/// the file's dialogue styles as `dialogueStyles(fromHeader:)` finds them.
/// Signs, songs and titles are left exactly as the release made them.
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
        case .simulcast: return "The classic simulcast look: Trebuchet MS, bold white, thick black outline, slight shadow."
        case .streaming: return "Clean sans, thin outline and a soft shadow."
        case .classicYellow: return "Bold yellow with a black outline, the DVD-era look."
        case .boxed: return "White on a translucent black box, readable over anything."
        }
    }

    /// The look itself, in one place, so the ASS overrides and the text
    /// options cannot drift apart. Colours are `0xAARRGGBB` with alpha as
    /// opacity (0xFF = solid).
    ///
    /// Sizes and widths are in the units of a 360-line script (PlayResY
    /// 360), the coordinate space the classic simulcast style was written
    /// in and the one SubsPlease still uses. `Scale` turns them into a given
    /// file's own units, or mpv's 720-line units for plain-text subtitles.
    struct Look {
        let font: String
        /// Line height, as ASS measures a style's size; nil keeps the
        /// release's own.
        let size: Double?
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
            // The classic simulcast Default style: Trebuchet MS 24, bold,
            // white, outline 2, shadow 1 in a 360-line script. Its size
            // matters as much as its font: at the release's own 26 the bold
            // Trebuchet read a size too large next to it.
            return Look(font: "Trebuchet MS", size: 24, bold: true, text: 0xFFFFFFFF, outline: 0xFF000000,
                        outlineWidth: 2, shadow: 0xFF000000, shadowOffset: 1, boxed: false)
        case .streaming:
            return Look(font: "Helvetica Neue", size: nil, bold: false, text: 0xFFFFFFFF, outline: 0xFF000000,
                        outlineWidth: 0.6, shadow: 0x90000000, shadowOffset: 0.8, boxed: false)
        case .classicYellow:
            return Look(font: "Arial", size: nil, bold: true, text: 0xFFFFE62E, outline: 0xFF000000,
                        outlineWidth: 1.4, shadow: 0x80000000, shadowOffset: 0.5, boxed: false)
        case .boxed:
            return Look(font: "Helvetica Neue", size: nil, bold: false, text: 0xFFFFFFFF, outline: 0xB0000000,
                        outlineWidth: 2.5, shadow: 0x00000000, shadowOffset: 0, boxed: true)
        }
    }

    /// `sub-ass-style-overrides` for the `styles` of a file whose script is
    /// `playResY` lines tall, or the empty string for `.release`, which
    /// clears whatever an earlier pick set. `Default` stands in until a
    /// header has been read.
    ///
    /// Size, outline and shadow are in the file's own script pixels, and a
    /// release's coordinate space is whatever its group chose: SubsPlease
    /// writes PlayResY 360, a BD group 720 or 1080. Written in any one unit
    /// they came out right for some files and doubled or halved on others
    /// (owner, on a 360-line SubsPlease file with 720-line widths: "much
    /// bigger than the standard one"), and left out entirely the preset lost
    /// the thick outline that makes the look ("looks completely off"). So
    /// they are scaled from 360-line units to the file's own here, and the
    /// player re-applies the style whenever the subtitle track changes.
    ///
    /// `crop` is the share of the picture cut off each edge by the phone's
    /// fill mode; the dialogue's vertical margin grows by it so bottom and top
    /// lines land on the screen instead of past it. Absolute, since an
    /// override cannot add to the file's value: the file's own 23 of 360
    /// lines, plus the crop.
    func assOverrides(playResY: Double = 360, styles: [String] = ["Default"], liftingBy crop: Double = 0) -> String {
        var fields: [(String, String)] = []
        let k = playResY / 360
        if let look {
            fields += [
                ("Fontname", look.font),
                ("Bold", look.bold ? "-1" : "0"),
                ("PrimaryColour", Self.assColour(look.text)),
                ("OutlineColour", Self.assColour(look.outline)),
                ("BackColour", Self.assColour(look.shadow)),
                ("BorderStyle", look.boxed ? "3" : "1"),
                ("Outline", Self.number(look.outlineWidth * k)),
                ("Shadow", Self.number(look.shadowOffset * k)),
            ]
            if let size = look.size { fields.append(("Fontsize", Self.number(size * k))) }
        }
        if crop > 0 {
            fields.append(("MarginV", "\(Int(((23.0 / 360) + crop) * playResY))"))
        }
        return styles
            .flatMap { style in fields.map { "\(style).\($0.0)=\($0.1)" } }
            .joined(separator: ",")
    }

    /// The script height libass uses for an ASS track, from its header (mpv's
    /// `sub-ass-extradata`). libass's own defaults when a field is missing:
    /// no PlayResY takes 3/4 of PlayResX (1024 for a 1280-wide script), and
    /// neither gives 288.
    static func playResY(fromHeader header: String) -> Double {
        func field(_ name: String) -> Double? {
            for line in header.split(whereSeparator: \.isNewline) where line.hasPrefix(name + ":") {
                return Double(line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        if let y = field("PlayResY"), y > 0 { return y }
        if let x = field("PlayResX"), x > 0 { return x == 1280 ? 1024 : x * 3 / 4 }
        return 288
    }

    /// The dialogue styles in an ASS header (mpv's `sub-ass-extradata`).
    ///
    /// A fixed list of names missed a quarter of the dialogue: over 125
    /// AnimeTosho tracks it covered 27,692 of 36,900 unpositioned lines, and
    /// a style like `On Top`, `main - italics` or `Flashback - Italics` kept
    /// the release's look between restyled `Default` lines, switching from
    /// one line to the next. Groups name their styles freely but give every
    /// dialogue variant the main style's font and size, so the styles named
    /// default, main or dialogue anchor the set (the first style, libass's
    /// fallback, when none is: `BD DX`), and every style sharing an anchor's
    /// font and size joins it. That covers 35,542 lines; what is left is
    /// OP, ED, songs, titles and signs. A sign style in the dialogue font
    /// (`MarySigns`, 1,908 positioned lines) is kept out by its name.
    static func dialogueStyles(fromHeader header: String) -> [String] {
        let styles: [(name: String, font: String, size: Double?)] = header
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("Style:") }
            .map { line in
                let fields = line.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return (fields[0], fields.count > 1 ? fields[1].lowercased() : "",
                        fields.count > 2 ? Double(fields[2]) : nil)
            }
            // mpv splits the override list on commas, and libass reads the
            // last `.` before `=` as the end of the name.
            .filter { !$0.name.isEmpty && !$0.name.contains(",") && !$0.name.contains("=") }
        let named = styles.filter { !words($0.name).isDisjoint(with: ["default", "main", "dialogue", "dialog"]) }
        let anchors = named.isEmpty ? Array(styles.prefix(1)) : named
        return styles
            .filter { style in anchors.contains { $0.font == style.font && $0.size == style.size } }
            .filter { style in !words(style.name).contains { $0.hasPrefix("sign") || $0.hasPrefix("song") } }
            .map(\.name)
    }

    /// A style name's words, lowercased: `DefaultItalicsTop` and
    /// `GJM_Main_1080p` both read as words, so `main` is found in the second
    /// without matching `domain`.
    static func words(_ name: String) -> Set<String> {
        var words: Set<String> = [], current = ""
        for ch in name {
            if !ch.isLetter || (ch.isUppercase && current.last?.isLowercase == true) {
                if !current.isEmpty { words.insert(current.lowercased()) }
                current = ch.isLetter ? String(ch) : ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.insert(current.lowercased()) }
        return words
    }

    /// mpv's `sub-*` options for plain-text subtitles. `.release` restores
    /// mpv's documented defaults, so switching back undoes a preset without
    /// restarting the player.
    var textOptions: [(String, String)] {
        guard let look else {
            return [
                ("sub-font", "sans-serif"), ("sub-bold", "no"), ("sub-font-size", "55"),
                ("sub-color", "#FFFFFFFF"), ("sub-border-color", "#FF000000"),
                ("sub-border-size", "3"), ("sub-shadow-offset", "0"),
                ("sub-shadow-color", "#F0000000"), ("sub-back-color", "#00000000"),
                ("sub-border-style", "outline-and-shadow"),
            ]
        }
        // mpv's `sub-*` sizes are in 720-line units, twice the 360-line ones.
        return [
            ("sub-font", look.font), ("sub-bold", look.bold ? "yes" : "no"),
            ("sub-font-size", Self.number((look.size ?? 26) * 2)),
            ("sub-color", Self.mpvColour(look.text)),
            ("sub-border-color", Self.mpvColour(look.outline)),
            ("sub-border-size", Self.number(look.outlineWidth * 2)),
            ("sub-shadow-offset", Self.number(look.shadowOffset * 2)),
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
