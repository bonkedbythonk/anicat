import SwiftUI
import CoreText
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Color Hex Initializer

extension Color {
    init(hex: String, opacity: Double = 1.0) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255 * opacity
        )
    }
}

// MARK: - Sumi Ledger Theme Tokens

public enum SumiTheme {
    // MARK: - Colors
    //
    // Every token is a computed property over `ThemeStore.shared.palette`.
    // They used to be `static let` dynamic `NSColor`s that answered the dark
    // or the light hex depending on the `NSAppearance` they were drawn under.
    // That cannot survive three explicit palettes: with OLED selected on a Mac
    // set to Light, the appearance-driven colour and the palette disagree and
    // every token silently answers with the wrong skin. The palette is now the
    // only chooser, and `ThemeStore.colorScheme` / `nsAppearance` exist purely
    // to tell native chrome which side it landed on.
    //
    // Reading a token is a struct field load, not a hex parse: `SumiPalette`
    // resolves each `Color` once at construction, which is what keeps a
    // scrolling grid from re-scanning a hex string per card per frame.

    /// Sumi Ink / Washi Paper / true black, depending on the palette.
    public static var background: Color { ThemeStore.shared.palette.background }

    /// The raised surface a card, sheet or row sits on.
    public static var card: Color { ThemeStore.shared.palette.card }

    // index.css defines `--card-color` and `--surface-color` as two separate
    // tokens that happen to share a value in every skin. Keeping both names
    // here (instead of collapsing call sites onto `card`) means a call site
    // ported from the web keeps the name it had there, so a future skin that
    // actually splits the two values only has to change this one line.
    public static var surface: Color { card }

    /// Primary foreground text.
    public static var foreground: Color { ThemeStore.shared.palette.foreground }

    /// Secondary text: the foreground at the palette's muted alpha.
    public static var muted: Color { ThemeStore.shared.palette.muted }

    /// Hairline border: the foreground at the palette's border alpha.
    public static var border: Color { ThemeStore.shared.palette.border }

    /// The single accent, Aizome Indigo. Honours `palette.accentOverride`, so
    /// a future poster-derived accent needs no change at any call site.
    public static var indigo: Color { ThemeStore.shared.palette.indigo }

    public static var indigoLight: Color { ThemeStore.shared.palette.indigoLight }

    // Status colours. Palette-scoped rather than shared: the `#F87171` that
    // reads as an error on Ink's near-black ground is a pale wash on Paper.
    public static var danger: Color { ThemeStore.shared.palette.danger }
    public static var dangerLight: Color { ThemeStore.shared.palette.dangerLight }
    public static var success: Color { ThemeStore.shared.palette.success }
    public static var successLight: Color { ThemeStore.shared.palette.successLight }
    public static var warning: Color { ThemeStore.shared.palette.warning }
    public static var warningLight: Color { ThemeStore.shared.palette.warningLight }

    /// The muted foreground at the alpha the poster tick's track uses, and
    /// the same 10% wash behind a progress bar or a shortcut chip.
    public static var foregroundWash: Color { foreground.opacity(0.10) }

    // MARK: - Radius
    public static let radiusSm: CGFloat = 6
    public static let radiusMd: CGFloat = 10
    public static let radiusLg: CGFloat = 12
    public static let radiusXl: CGFloat = 14
    public static let radius2Xl: CGFloat = 16
    public static let radius3Xl: CGFloat = 20
    
    // MARK: - Spacing
    public static let spaceSm: CGFloat = 8
    public static let spaceMd: CGFloat = 16
    public static let spaceLg: CGFloat = 24
    
}

// MARK: - Typography Modifiers

/// `.meta-mono` from index.css: uppercase mono with tabular figures, the
/// skin's signature for anything that carries state (EP 11 / 25, WATCHED 6H
/// AGO). Never for titles or button labels — those stay sentence case.
///
/// The uppercasing is the part that is easy to lose and most visible when it
/// is: without it the same string renders "1 in progress" here and
/// "1 IN PROGRESS" on the web, and every metadata line in the app reads as a
/// different design. Tracking is `0.08em`, so it scales with the size rather
/// than being one hardcoded point value across call sites from 9pt to 11.5pt.
// MARK: - Typography Manager & Extensions

public enum SumiFontManager {
    nonisolated(unsafe) private static var isRegistered = false

    public static func registerCustomFonts() {
        guard !isRegistered else { return }
        isRegistered = true

        let fontFiles = [
            "Geist.ttf",
            "IBMPlexMono-Regular.ttf",
            "IBMPlexMono-Medium.ttf",
            "IBMPlexMono-SemiBold.ttf"
        ]

        for file in fontFiles {
            let candidates: [URL?] = [
                Bundle.module.url(forResource: file, withExtension: nil),
                Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fonts"),
                Bundle.main.url(forResource: file, withExtension: nil),
                Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Fonts"),
                Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(file)"),
                Bundle.main.resourceURL?.appendingPathComponent(file)
            ]
            for case let url? in candidates {
                if FileManager.default.fileExists(atPath: url.path) {
                    var error: Unmanaged<CFError>?
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                    break
                }
            }
        }
    }

    public static let isGeistAvailable: Bool = {
        registerCustomFonts()
        #if os(macOS)
        return NSFont(name: "Geist-Regular", size: 12) != nil || NSFont(name: "Geist", size: 12) != nil
        #elseif canImport(UIKit)
        return UIFont(name: "Geist-Regular", size: 12) != nil || UIFont(name: "Geist", size: 12) != nil
        #else
        return false
        #endif
    }()

    public static let isIBMPlexMonoAvailable: Bool = {
        registerCustomFonts()
        #if os(macOS)
        return NSFont(name: "IBMPlexMono-Regular", size: 12) != nil || NSFont(name: "IBM Plex Mono", size: 12) != nil
        #elseif canImport(UIKit)
        return UIFont(name: "IBMPlexMono-Regular", size: 12) != nil || UIFont(name: "IBM Plex Mono", size: 12) != nil
        #else
        return false
        #endif
    }()
}

public extension Font {
    static func sumiSans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if SumiFontManager.isGeistAvailable {
            return .custom("Geist", size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// Titles — page and section headers, and every title that names a thing:
    /// a poster card, an episode row, a chapter, a relation, a character, a
    /// shelf. The one call that varies with the palette:
    /// Sakura Zen sets them in a serif face (`Noto Serif JP` in the web
    /// build, New York here), every other skin gets the same system sans it
    /// always had, so this is a no-op everywhere but Sakura.
    ///
    /// Reading the palette here rather than at the call sites is what keeps a
    /// theme switch landing: this is called from inside a `body`, so
    /// Observation registers it exactly as a colour token read would. A
    /// heading font hoisted into a `static let` or a struct-scope constant
    /// would not come back — the same trap `ThemedRoot` documents for colours.
    ///
    /// What stays on `.system` is the line: body prose (synopses,
    /// descriptions, settings copy), every button and control label, empty
    /// states and error text, author names, technical strings (release
    /// candidates, downloaded filenames), and the player's own chrome, which
    /// is pinned to the Ink palette whatever the app is set to. The metadata
    /// register stays IBM Plex Mono in every skin — the stamped index-card
    /// line is the app's signature, not Ink & Index's alone.
    static func sumiHeading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if ThemeStore.shared.palette.usesSerifHeadings {
            return .system(size: size, weight: weight, design: .serif)
        }
        return .system(size: size, weight: weight)
    }

    static func sumiMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if SumiFontManager.isIBMPlexMonoAvailable {
            let fontName: String
            switch weight {
            case .semibold, .bold, .heavy, .black:
                fontName = "IBMPlexMono-SemiBold"
            case .medium:
                fontName = "IBMPlexMono-Medium"
            default:
                fontName = "IBMPlexMono-Regular"
            }
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Mono and tabular figures, for content that is actually figures: a
/// timecode, `EP 10 / 12`, a countdown, a byte size, a version.
///
/// It used to force `.textCase(.uppercase)` as well, which fused two
/// unrelated jobs into one modifier -- so anything that wanted digits not to
/// jitter also got shouted in wide-tracked capitals, prose included.
/// "Watched 3h ago" and "Episode 10" rendered as WATCHED 3H AGO and
/// EPISODE 10. Monospace plus forced caps plus letterspacing on running
/// words is the house style of a generic dashboard, and it read as one.
///
/// Strings written in capitals at the call site still render in capitals, so
/// deliberate headings are unaffected; only sentence case is left alone now.
/// For a heading, reach for `sumiLabelCaps` instead -- caps belong to a label
/// style, not to a numeric one.
public struct SumiLabelCaps: ViewModifier {
    var size: CGFloat = 10
    var weight: Font.Weight = .semibold

    public func body(content: Content) -> some View {
        content
            .font(.sumiSans(size: size, weight: weight))
            .textCase(.uppercase)
            .tracking(size * 0.09)
    }
}

/// How wide the shelf column is allowed to be, given the space it has.
///
/// A flat 1280pt cap was right for a laptop and wrong for anything much
/// wider: on a 3440pt ultrawide it left ~400pt of empty band on *each* side
/// of a marooned column, and -- worse than the emptiness -- truncated titles
/// and squeezed the week strip while the screen sat unused. Simulated at
/// matching proportions before changing it, which is how the truncation
/// showed up at all.
///
/// The shelves are horizontal scrollers, so width spent here buys more
/// posters per row and untruncated titles rather than stretched ones. Still
/// bounded at both ends: below 1280 the rows lose their measure, and past
/// 2200 a shelf becomes a row nobody can scan in one look.
///
/// Detail pages keep their own narrower cap on purpose -- that one is a
/// reading measure for prose, and prose does not want the extra width.
public enum SumiContentWidth {
    public static let floor: CGFloat = 1280
    public static let ceiling: CGFloat = 2200
    /// Leaves a margin either side rather than filling edge to edge, so the
    /// column still reads as a column.
    public static let share: CGFloat = 0.72

    /// Never wider than what it was given. The floor is a preference, not a
    /// demand: the window minimum is 1080pt, and a floor of 1280 applied
    /// unconditionally would have made the column wider than the window and
    /// clipped it -- the previous `maxWidth` shrank to fit instead, so this
    /// would have been a regression on every narrow window.
    public static func forAvailable(_ width: CGFloat) -> CGFloat {
        min(min(max(floor, width * share), ceiling), width)
    }
}

// Applied as `.frame(maxWidth:)` against a width measured *outside* the
// scroll view, never as `containerRelativeFrame`. That set an exact width,
// and an exact width can exceed the viewport: measured inside the scroll
// view the container came back as the greedy content rather than the
// viewport, so shrinking the window pushed the whole page -- sidebar
// included -- off the left edge. A `maxWidth` can only ever shrink.

public struct SumiTabularMono: ViewModifier {
    var size: CGFloat = 11.5
    var weight: Font.Weight = .regular

    public func body(content: Content) -> some View {
        content
            .font(.sumiMono(size: size, weight: weight))
            .monospacedDigit()
            .tracking(size * 0.08)
    }
}

/// Every button in the app used plain `.buttonStyle(.sumiPressable)` — no visual
/// response to mouse-down at all, only the separate hover states each view
/// wired up by hand. Native AppKit controls always give that instantaneous
/// press feedback (a slight scale/dim on click, springing back on release);
/// without it the whole app reads as flat/web-like no matter how good the
/// hover and transition curves are. This is a drop-in replacement for
/// `.plain` that adds it back.
/// The one definition of "what pressed looks like" in the app — both
/// `SumiPressableButtonStyle` (for `Button`) and `SumiMenuPressable` (for
/// `Menu`, which ignores `ButtonStyle` entirely) apply this to their own
/// press signal so retuning the feel means changing it once, not twice.
private enum SumiPressFeedback {
    static let scale: CGFloat = 0.97
    static let opacity: Double = 0.85
}

public struct SumiPressableButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? SumiPressFeedback.scale : 1.0)
            .opacity(configuration.isPressed ? SumiPressFeedback.opacity : 1.0)
            .animation(.snappy, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == SumiPressableButtonStyle {
    static var sumiPressable: SumiPressableButtonStyle { SumiPressableButtonStyle() }
}

/// `Menu`'s label ignores `.buttonStyle` entirely — a `ButtonStyle` only ever
/// applies to `Button`, so every `Menu`-based control in the app (dropdowns,
/// the detail page's status/overflow menus) silently lost the press feedback
/// every `Button` gets from `.sumiPressable`. This fakes the same scale/dim
/// dip from a raw press gesture, applied to the Menu's label view instead.
private struct SumiMenuPressable: ViewModifier {
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? SumiPressFeedback.scale : 1.0)
            .opacity(isPressed ? SumiPressFeedback.opacity : 1.0)
            .animation(.snappy, value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}

public extension View {
    func sumiMenuPressable() -> some View {
        modifier(SumiMenuPressable())
    }
}

public extension View {
    /// Applies a modifier only when `value` is non-nil, without the caller
    /// needing an `if let`/`else` branch that would otherwise fork the view
    /// tree into two distinct identities — used for optional namespaces
    /// (`matchedGeometryEffect`) and similar modifiers where a nil case
    /// should just be a no-op.
    @ViewBuilder
    func ifLet<Value, Content: View>(_ value: Value?, @ViewBuilder transform: (Self, Value) -> Content) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

public extension View {
    /// A small capitalised heading in the sans face. The caps and the
    /// tracking are the point here; the monospace face is not, and using the
    /// numeric modifier for headings is what made them look machine-set.
    func sumiLabelCaps(size: CGFloat = 10, weight: Font.Weight = .semibold) -> some View {
        modifier(SumiLabelCaps(size: size, weight: weight))
    }

    func sumiTabularMono(size: CGFloat = 11.5, weight: Font.Weight = .regular) -> some View {
        modifier(SumiTabularMono(size: size, weight: weight))
    }
    
    func sumiCardStyle() -> some View {
        self
            .background(SumiTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusXl))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusXl)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
    }
}

// MARK: - Haptic Feedback

public enum SumiHaptics {
    @MainActor
    public static func selection() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #elseif canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
        #endif
    }
}

// MARK: - Motion Tokens

public extension Animation {
    /// The pill-and-indicator spring, as an alias for the occasion that
    /// already names it.
    ///
    /// This used to spell its own `.spring(response: 0.30, dampingFraction:
    /// 0.82)` — the same numbers `sumi(.pop)` returns, but reaching no
    /// further, so all nine call sites went on springing after the system
    /// asked for less motion. `MotionPolicy` is the only thing that knows
    /// about that setting, and a bare `.spring` cannot ask it.
    static var sumiSpring: Animation { .sumi(.pop) }
}


