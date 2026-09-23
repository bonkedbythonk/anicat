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

    /// The favourite heart. The same rose on every skin: AniList's own
    /// favourite is pink, and a heart that changed hue with the accent read
    /// as a second state rather than the same one. Muted from Tailwind's
    /// pink-500 (`#EC4899`), which glowed as a second accent beside the
    /// indigo; the light-ground shade keeps it at 4.4:1 on Paper.
    public static var favourite: Color {
        Color(hex: ThemeStore.shared.palette.isLight ? "#B24B63" : "#D86F86")
    }

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

        // Geist is only the reader's optional body face now; the app's own
        // text is all SF Pro.
        let fontFiles = ["Geist.ttf"]

        for file in fontFiles {
            let candidates: [URL?] = [
                Bundle.anicatResources.url(forResource: file, withExtension: nil),
                Bundle.anicatResources.url(forResource: file, withExtension: nil, subdirectory: "Fonts"),
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
    /// is pinned to the Ink palette whatever the app is set to.
    static func sumiHeading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if ThemeStore.shared.palette.usesSerifHeadings {
            return .system(size: size, weight: weight, design: .serif)
        }
        return .system(size: size, weight: weight)
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

/// Metadata and figures: a timecode, `Ep 10 / 12`, a countdown, a byte
/// size, a status word. SF Pro with fixed-width digits, so a ticking
/// timecode does not jitter, in sentence case as written at the call site.
///
/// It was IBM Plex Mono with 8% tracking, and for a while forced capitals
/// too. Uppercase tracked monospace on words -- AIRING, TRAILER, MORE FROM
/// MAPPA -- read as generic dashboard chrome rather than a Mac app, and
/// wrapping those labels in tinted capsules made it louder. Only the digits
/// ever needed a fixed width; `.monospacedDigit()` gives that in SF Pro.
public struct SumiTabularMono: ViewModifier {
    var size: CGFloat = 11.5
    var weight: Font.Weight = .regular

    public func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight))
            .monospacedDigit()
    }
}

/// Press feedback for the app's custom tappables: poster cards, rows, text
/// links, icon buttons. Anything that looks like a push button uses the
/// native styles below instead. A dim, not a shrink: every control used to
/// scale to 97% on press, the web's `active:scale` habit, and no Mac control
/// moves under the pointer. Shared with `SumiMenuPressable`, which has to
/// fake the same dip for `Menu`.
private enum SumiPressFeedback {
    static let opacity: Double = 0.85
}

public struct SumiPressableButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? SumiPressFeedback.opacity : 1.0)
            .animation(.snappy, value: configuration.isPressed)
            // Every button in the app answers under the finger, rather than
            // the handful of controls that remembered to ask. On the press
            // edge, not the action: the tick belongs to the press being
            // registered, and plenty of these actions are async.
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { SumiHaptics.selection() }
            }
    }
}

public extension ButtonStyle where Self == SumiPressableButtonStyle {
    static var sumiPressable: SumiPressableButtonStyle { SumiPressableButtonStyle() }
}

/// `Menu`'s label ignores `.buttonStyle` entirely — a `ButtonStyle` only ever
/// applies to `Button`, so every `Menu`-based control in the app (dropdowns,
/// the detail page's status/overflow menus) silently lost the press feedback
/// every `Button` gets from `.sumiPressable`. This fakes the same dim from a
/// raw press gesture, applied to the Menu's label view instead.
private struct SumiMenuPressable: ViewModifier {
    @State private var isPressed = false

    func body(content: Content) -> some View {
        #if os(tvOS)
        // No drag on a Siri Remote, and the focus engine already lifts and
        // dims a focused control; a second press effect on top of that
        // reads as a glitch.
        content
        #else
        content
            .opacity(isPressed ? SumiPressFeedback.opacity : 1.0)
            .animation(.snappy, value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        #endif
    }
}

public extension View {
    func sumiMenuPressable() -> some View {
        modifier(SumiMenuPressable())
    }
}

/// The app's push buttons, drawn in Sumi: an indigo fill for the one action a
/// screen is for, a card fill with a hairline for the rest. Sized from
/// `controlSize` so call sites say how big, not how to draw. The native
/// bordered styles were tried and read as stock system chrome, not Anicat.
public struct SumiButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary }
    let kind: Kind

    public func makeBody(configuration: Configuration) -> some View {
        SumiButtonBody(kind: kind, configuration: configuration)
    }
}

private struct SumiButtonBody: View {
    let kind: SumiButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let isPrimary = kind == .primary
        let isDestructive = configuration.role == .destructive
        let (height, padding, fontSize): (CGFloat, CGFloat, CGFloat) = switch controlSize {
        case .mini, .small: (24, 10, 11.5)
        case .large: (34, 16, 12.5)
        case .extraLarge: (40, isPrimary ? 20 : 16, isPrimary ? 13.5 : 12.5)
        default: (28, 14, 12)
        }
        let radius = isPrimary && controlSize == .extraLarge ? SumiTheme.radiusLg : SumiTheme.radiusMd
        let shape = RoundedRectangle(cornerRadius: radius)
        configuration.label
            .font(.system(size: fontSize, weight: isPrimary ? .bold : .semibold))
            .labelStyle(SumiButtonLabelStyle())
            .lineLimit(1)
            .foregroundColor(isPrimary ? SumiTheme.background : (isDestructive ? SumiTheme.danger : SumiTheme.foreground))
            .padding(.horizontal, padding)
            .frame(minHeight: height)
            .background(isPrimary
                ? SumiTheme.indigo.opacity(isHovered ? 0.85 : 1)
                : (isHovered ? SumiTheme.foregroundWash : SumiTheme.card))
            .clipShape(shape)
            .overlay(shape.stroke(isPrimary ? Color.clear : SumiTheme.border, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .animation(.snappy, value: isHovered)
            .stableHover { isHovered = $0 }
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { SumiHaptics.selection() }
            }
    }
}

/// Icon a size down from the title, as the hand-drawn buttons had it.
private struct SumiButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

public extension View {
    /// The one action a screen is for: Resume, Continue, Save.
    @ViewBuilder
    func sumiPrimaryButton() -> some View {
        #if os(tvOS)
        // A custom style loses the focus engine's lift; the TV keeps the
        // platform button.
        buttonStyle(.borderedProminent)
        #else
        buttonStyle(SumiButtonStyle(kind: .primary))
        #endif
    }

    /// Every other push button.
    @ViewBuilder
    func sumiSecondaryButton() -> some View {
        #if os(tvOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(SumiButtonStyle(kind: .secondary))
        #endif
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
    /// The tick under a press that changes something.
    ///
    /// `.levelChange`, not `.alignment`. AppKit's alignment pattern is the
    /// faint one meant for a guide snapping under a drag, and fired at click
    /// time it is barely there -- the app read as having no trackpad feedback
    /// at all even where this was already being called. `.alignment` stays in
    /// `AppHaptics.swipeThreshold`, which is the case it was designed for.
    ///
    /// `.drawCompleted` rather than `.now`: the tap lands with the frame that
    /// shows the change instead of a beat before it.
    /// The last tick, so two sources firing for one press are felt as one.
    /// `.sumiPressable` fires on the press edge and a good number of call
    /// sites also call this from their action; 80ms apart those are a double
    /// tap under the finger, which reads as a stutter rather than a click.
    @MainActor
    private static var lastFired: CFAbsoluteTime = 0

    @MainActor
    public static func selection() {
        guard FeedbackDefaults.hapticsEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFired > 0.08 else { return }
        lastFired = now
        #if os(macOS)
        // Nothing on the Mac. A Force Touch trackpad already clicks on the
        // press and again on the release; a `.levelChange` on top of that
        // was felt as three clicks per card, which the owner called out.
        // Trackpad feedback stays for the gestures that have no click of
        // their own: `AppHaptics.swipeThreshold`.
        // `os(iOS)`, not `canImport(UIKit)`: tvOS imports UIKit and has no
        // feedback generators.
        #elseif os(iOS)
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


