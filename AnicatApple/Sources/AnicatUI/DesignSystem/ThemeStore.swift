import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Palette

/// One complete set of the tokens `SumiTheme` publishes.
///
/// Every colour is stored twice: as the source hex string and as the resolved
/// `Color`. The resolved copy exists because `SumiTheme.foreground` is read
/// about 950 times across the views, several of them inside scrolling grids —
/// re-running the hex `Scanner` on each read is work that shows up in a scroll.
/// The hex copy exists because a `Color` cannot hand its channels back without
/// a platform colour and a display environment, which a headless test process
/// does not have; the WCAG contrast checks do integer maths on these strings
/// instead.
public struct SumiPalette: Sendable {
    public let id: String
    public let name: String

    /// True for a ground the eye reads as paper. Drives `colorScheme` and
    /// `nsAppearance`, which is the only reason native chrome (menus,
    /// scrollers, focus rings, text selection) matches the palette.
    public let isLight: Bool

    public let backgroundHex: String
    public let cardHex: String
    public let foregroundHex: String
    public let indigoHex: String
    public let indigoLightHex: String
    public let mutedAlpha: Double
    public let borderAlpha: Double

    /// Whether page and section titles are set in a serif face. The palette's
    /// only non-colour axis, and it exists for one skin: Sakura Zen set
    /// `Noto Serif JP` on h1-h6 in the web build, and without it the port is
    /// a recolour rather than the skin. Read through `Font.sumiHeading`.
    public let usesSerifHeadings: Bool

    public let background: Color
    public let card: Color
    public let foreground: Color
    public let muted: Color
    public let border: Color
    public let indigoLight: Color

    public let danger: Color
    public let dangerLight: Color
    public let success: Color
    public let successLight: Color
    public let warning: Color
    public let warningLight: Color

    private let baseIndigo: Color

    /// The hook for "accent from the current poster". Nothing sets it yet;
    /// when something does, it replaces the accent for the whole app without
    /// any call site learning a second token name.
    public var accentOverride: Color?

    public var indigo: Color { accentOverride ?? baseIndigo }

    public init(
        id: String,
        name: String,
        isLight: Bool,
        backgroundHex: String,
        cardHex: String,
        foregroundHex: String,
        indigoHex: String,
        indigoLightHex: String,
        mutedAlpha: Double,
        borderAlpha: Double,
        usesSerifHeadings: Bool = false,
        dangerHex: String,
        dangerLightHex: String,
        successHex: String,
        successLightHex: String,
        warningHex: String,
        warningLightHex: String
    ) {
        self.id = id
        self.name = name
        self.isLight = isLight
        self.backgroundHex = backgroundHex
        self.cardHex = cardHex
        self.foregroundHex = foregroundHex
        self.indigoHex = indigoHex
        self.indigoLightHex = indigoLightHex
        self.mutedAlpha = mutedAlpha
        self.borderAlpha = borderAlpha
        self.usesSerifHeadings = usesSerifHeadings

        self.background = Color(hex: backgroundHex)
        self.card = Color(hex: cardHex)
        self.foreground = Color(hex: foregroundHex)
        self.muted = Color(hex: foregroundHex, opacity: mutedAlpha)
        self.border = Color(hex: foregroundHex, opacity: borderAlpha)
        self.baseIndigo = Color(hex: indigoHex)
        self.indigoLight = Color(hex: indigoLightHex)
        self.danger = Color(hex: dangerHex)
        self.dangerLight = Color(hex: dangerLightHex)
        self.success = Color(hex: successHex)
        self.successLight = Color(hex: successLightHex)
        self.warning = Color(hex: warningHex)
        self.warningLight = Color(hex: warningLightHex)
    }
}

// MARK: - The palettes

public extension SumiPalette {
    /// "Ink & Index", the skin the app shipped with and still starts in.
    static let ink = SumiPalette(
        id: "ink",
        name: "Ink & Index",
        isLight: false,
        backgroundHex: "#161310",
        cardHex: "#1E1A15",
        foregroundHex: "#EDE7DC",
        indigoHex: "#8FB8DC",
        indigoLightHex: "#A8C9E6",
        mutedAlpha: 0.55,
        borderAlpha: 0.10,
        dangerHex: "#EF4444",
        dangerLightHex: "#F87171",
        successHex: "#22C55E",
        successLightHex: "#4ADE80",
        warningHex: "#EAB308",
        warningLightHex: "#FACC15"
    )

    /// Washi paper. The accent is darkened from Ink's `#8FB8DC`, which measures
    /// 1.77:1 against this ground and disappears entirely as a hairline or a
    /// small label; `#2F5A76` measures 6.27:1. The status colours are darkened
    /// for the same reason.
    static let paper = SumiPalette(
        id: "paper",
        name: "Paper",
        isLight: true,
        backgroundHex: "#F1ECE2",
        cardHex: "#FAF7F0",
        foregroundHex: "#26221B",
        indigoHex: "#2F5A76",
        indigoLightHex: "#45789A",
        mutedAlpha: 0.65,
        borderAlpha: 0.14,
        dangerHex: "#B91C1C",
        dangerLightHex: "#DC2626",
        successHex: "#15803D",
        successLightHex: "#16A34A",
        warningHex: "#A16207",
        warningLightHex: "#CA8A04"
    )

    /// True black for OLED panels. The foreground scale is Ink's, but the
    /// hairline alpha goes 0.10 -> 0.18: 10% of `#EDE7DC` over `#161310`
    /// composites to `#2C2824`, a 1.27:1 seam that reads; the same 10% over
    /// `#000000` composites to `#181716` at 1.17:1, which the panel renders as
    /// very nearly the unlit ground next to it, and every card in the app
    /// loses its edge. 0.18 puts it back at 1.46:1.
    static let oled = SumiPalette(
        id: "oled",
        name: "OLED",
        isLight: false,
        backgroundHex: "#000000",
        cardHex: "#0B0A09",
        foregroundHex: "#EDE7DC",
        indigoHex: "#8FB8DC",
        indigoLightHex: "#A8C9E6",
        mutedAlpha: 0.58,
        borderAlpha: 0.18,
        dangerHex: "#EF4444",
        dangerLightHex: "#F87171",
        successHex: "#22C55E",
        successLightHex: "#4ADE80",
        warningHex: "#EAB308",
        warningLightHex: "#FACC15"
    )

    /// "Sakura Zen", the alt skin the Tauri app carried as
    /// `data-style="sakura-zen"`: cherry-dark ground, plum-tinted chrome, one
    /// blossom accent. Ported at the CSS's own hex values, all of which clear
    /// the suite's floors unchanged (foreground 18.54:1, accent 5.64:1).
    ///
    /// The CSS's separate `--surface-color` (`#2A151D` dark, `#FAEBEF` light)
    /// is dropped rather than ported: in the Swift app the sidebar is a
    /// vibrancy material tinted with the *ground*, so nothing would have read
    /// it. The alpha-derived hairline also loses the CSS's `#422534`, which is
    /// plummier than the near-white foreground it is now derived from; 0.16
    /// matches its lightness (1.53:1) and the tint is the part that does not
    /// survive a single-foreground palette. The CSS's `letter-spacing:
    /// -0.01em` on headings has no equivalent either: tracking is a view
    /// modifier, not part of a `Font`, so it cannot vary per palette — the
    /// heading call sites that care already carry a hand-tuned
    /// `.tracking(-0.3)`, which is the same order (-0.19pt at 19pt).
    static let sakura = SumiPalette(
        id: "sakura",
        name: "Sakura Zen",
        isLight: false,
        backgroundHex: "#180A10",
        cardHex: "#201016",
        foregroundHex: "#FCFAFB",
        indigoHex: "#E0607E",
        indigoLightHex: "#EA8EA3",
        mutedAlpha: 0.55,
        borderAlpha: 0.16,
        usesSerifHeadings: true,
        dangerHex: "#EF4444",
        dangerLightHex: "#F87171",
        successHex: "#22C55E",
        successLightHex: "#4ADE80",
        warningHex: "#EAB308",
        warningLightHex: "#FACC15"
    )

    /// Sakura Zen's light half: sakura paper under deep plum ink. The accent
    /// is `#C04060` at 4.73:1 — it clears AA normal, but by 0.23, so it is the
    /// one accent in the app that a nudge toward its dark sibling's `#E0607E`
    /// (2.55:1 here) would break. Status colours come from Paper, which
    /// darkened them for exactly this ground.
    static let sakuraLight = SumiPalette(
        id: "sakura-light",
        name: "Sakura Light",
        isLight: true,
        backgroundHex: "#FDF5F7",
        cardHex: "#FFFFFF",
        foregroundHex: "#2D1822",
        indigoHex: "#C04060",
        indigoLightHex: "#D86884",
        mutedAlpha: 0.65,
        borderAlpha: 0.12,
        usesSerifHeadings: true,
        dangerHex: "#B91C1C",
        dangerLightHex: "#DC2626",
        successHex: "#15803D",
        successLightHex: "#16A34A",
        warningHex: "#A16207",
        warningLightHex: "#CA8A04"
    )

    /// Every palette that ships, derived from the skins rather than listed by
    /// hand. A hand-kept list is how a skin's light half reaches users with no
    /// contrast checking at all: the suite loops over this, so a palette
    /// missing from it is a palette nothing measures.
    static let all: [SumiPalette] = SumiSkin.allCases.flatMap { skin in
        [skin.dark] + (skin.light.map { [$0] } ?? [])
    }
}

// MARK: - WCAG contrast

public extension SumiPalette {
    /// Relative luminance of an `#RRGGBB` string, per WCAG 2.1. Alpha is
    /// ignored: a token drawn at 55% over a known ground is a composite, and
    /// the caller that cares composites first.
    static func relativeLuminance(hex: String) -> Double {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        // Spelled out step by step: the array literal of three shifted
        // divisions plus the mapped ternary was one expression, and CI's
        // toolchain gave up type-checking it ("unable to type-check this
        // expression in reasonable time") while the local one passed.
        let red: Double = Double((int >> 16) & 0xFF) / 255.0
        let green: Double = Double((int >> 8) & 0xFF) / 255.0
        let blue: Double = Double(int & 0xFF) / 255.0
        func linear(_ channel: Double) -> Double {
            if channel <= 0.03928 { return channel / 12.92 }
            return pow((channel + 0.055) / 1.055, 2.4)
        }
        let r: Double = 0.2126 * linear(red)
        let g: Double = 0.7152 * linear(green)
        let bl: Double = 0.0722 * linear(blue)
        return r + g + bl
    }

    /// WCAG contrast ratio between two `#RRGGBB` strings, 1.0 to 21.0.
    static func contrastRatio(_ a: String, _ b: String) -> Double {
        let la = relativeLuminance(hex: a)
        let lb = relativeLuminance(hex: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Body text on this palette's ground.
    var foregroundContrast: Double {
        Self.contrastRatio(foregroundHex, backgroundHex)
    }

    /// The accent on this palette's ground. Uses the palette's own accent,
    /// not an override: an override is poster-derived and unvalidated.
    var accentContrast: Double {
        Self.contrastRatio(indigoHex, backgroundHex)
    }
}

// MARK: - Theme selection

/// A skin: one identity, drawn on a dark ground and, where it has one, on a
/// light one.
///
/// The picker used to list every palette flat, which put Paper and Sakura
/// Light in it as peers of the skins they are the light half of — two white
/// swatches in a row of six, and no way to tell that picking Paper was
/// picking Ink in daylight. Light/dark is now an `AnicatAppearance` beside
/// the skin, not a second entry inside it.
public enum SumiSkin: String, CaseIterable, Sendable, Identifiable {
    case ink
    case sakura
    case oled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ink: return "Ink & Index"
        case .sakura: return "Sakura Zen"
        case .oled: return "OLED"
        }
    }

    public var caption: String {
        switch self {
        case .ink: return "Warm sumi ink, washi paper by day"
        case .sakura: return "Cherry dark, sakura paper by day"
        case .oled: return "True black. Dark only"
        }
    }

    public var dark: SumiPalette {
        switch self {
        case .ink: return .ink
        case .sakura: return .sakura
        case .oled: return .oled
        }
    }

    /// `nil` for a skin with no light half. OLED is that skin and always will
    /// be: it exists to switch pixels off, which a light ground cannot do.
    /// The appearance control hides itself for a skin that answers `nil` here
    /// rather than offering a Light that silently does nothing.
    public var light: SumiPalette? {
        switch self {
        case .ink: return .paper
        case .sakura: return .sakuraLight
        case .oled: return nil
        }
    }

    public var hasLight: Bool { light != nil }

    public func palette(isLight: Bool) -> SumiPalette {
        isLight ? (light ?? dark) : dark
    }
}

/// Which side of the skin is in force. `system` is a resolution rule, not a
/// palette; `light` on a skin with no light half resolves to its dark, which
/// is why the control is hidden there rather than disabled.
public enum AnicatAppearance: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "Follow system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public func isLight(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: return !systemIsDark
        case .light: return true
        case .dark: return false
        }
    }
}

/// The single key this used to persist, and the six values it could hold.
///
/// Kept only to read a build older than the split — it is migrated to
/// `anicat_skin` + `anicat_appearance` at the first launch after and never
/// written again. Deleting it resets everyone who has not launched since to
/// Ink/Follow-system, which is why it stays.
enum LegacyAnicatTheme: String {
    case ink, paper, oled, sakura, sakuraLight, system

    var migrated: (skin: SumiSkin, appearance: AnicatAppearance) {
        switch self {
        case .ink: return (.ink, .dark)
        case .paper: return (.ink, .light)
        case .oled: return (.oled, .dark)
        case .sakura: return (.sakura, .dark)
        case .sakuraLight: return (.sakura, .light)
        case .system: return (.ink, .system)
        }
    }
}

// MARK: - Theme store

/// The one mutable holder of the current palette.
///
/// Not `@MainActor`: `SumiTheme`'s tokens read through here, and those are
/// read from `NSViewRepresentable` coordinators and from a couple of
/// non-isolated helpers, so main-actor isolation here would push `await` into
/// call sites that only want a colour. Writes go through `select`, which is
/// main-actor; `@unchecked Sendable` records that, the same bargain `AppModel`
/// makes.
@Observable
public final class ThemeStore: @unchecked Sendable {
    public static let shared = ThemeStore()

    /// Spelled literally at every `@AppStorage` in Settings too — the property
    /// wrapper needs a literal — so the two must agree.
    public static let skinKey = "anicat_skin"
    public static let appearanceKey = "anicat_appearance"
    /// The pre-split key. Read once, migrated, then left alone.
    public static let legacyKey = "anicat_theme"

    public private(set) var skin: SumiSkin
    public private(set) var appearance: AnicatAppearance
    public private(set) var palette: SumiPalette

    public var colorScheme: ColorScheme { palette.isLight ? .light : .dark }

    #if os(macOS)
    /// What `NSApp.appearance` should be pinned to. The palette is the only
    /// thing that picks colours now, so this is not how tokens resolve — it is
    /// how the chrome we do not draw (menus, scrollers, focus rings, the text
    /// selection colour in a `TextField`) is told which side it is on.
    public var nsAppearance: NSAppearance? {
        NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
    }
    #endif

    private init() {
        let defaults = UserDefaults.standard
        let storedSkin = defaults.string(forKey: Self.skinKey).flatMap(SumiSkin.init(rawValue:))
        let storedAppearance = defaults.string(forKey: Self.appearanceKey).flatMap(AnicatAppearance.init(rawValue:))

        let skin: SumiSkin
        let appearance: AnicatAppearance
        if let storedSkin, let storedAppearance {
            skin = storedSkin
            appearance = storedAppearance
        } else {
            // First launch after the split, or the very first launch. The old
            // key held both halves in one value; an unreadable one lands on
            // the same Ink/Follow-system a fresh install gets.
            let legacy = defaults.string(forKey: Self.legacyKey).flatMap(LegacyAnicatTheme.init(rawValue:))
            let migrated = legacy?.migrated ?? (skin: SumiSkin.ink, appearance: AnicatAppearance.system)
            skin = migrated.skin
            appearance = migrated.appearance
            defaults.set(migrated.skin.rawValue, forKey: Self.skinKey)
            defaults.set(migrated.appearance.rawValue, forKey: Self.appearanceKey)
        }

        self.skin = skin
        self.appearance = appearance
        self.palette = skin.palette(
            isLight: appearance.isLight(systemIsDark: Self.systemPrefersDark)
        )
        observeSystemAppearance()
    }

    @MainActor
    public func select(_ skin: SumiSkin) {
        guard skin != self.skin else { return }
        self.skin = skin
        UserDefaults.standard.set(skin.rawValue, forKey: Self.skinKey)
        animateToNewPalette()
    }

    @MainActor
    public func select(_ appearance: AnicatAppearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        animateToNewPalette()
    }

    /// Swaps the palette inside an animated transaction, so every token read
    /// in a body tweens from the old colour to the new one instead of cutting.
    ///
    /// `.tab` rather than `.page`: half of a light/dark switch cannot be
    /// animated at all. `preferredColorScheme` and `NSApp.appearance` flip
    /// native chrome — scrollers, menus, focus rings, the text selection
    /// colour — in a single frame, so the longer the app's own fade runs the
    /// longer that seam is on screen beside it. Under reduced motion
    /// `Animation.sumi` collapses this to the house fade on its own.
    @MainActor
    private func animateToNewPalette() {
        withAnimation(.sumi(.tab)) {
            refresh()
        }
        applyToNativeChrome()
    }

    /// The palette a skin would resolve to right now — what its swatch draws,
    /// so the swatch is never a lie about the appearance in force.
    public func previewPalette(for skin: SumiSkin) -> SumiPalette {
        skin.palette(isLight: appearance.isLight(systemIsDark: Self.systemPrefersDark))
    }

    /// Sets the app-wide accent, or clears it back to the palette's own.
    /// Nothing calls this yet; it is the poster-accent hook.
    @MainActor
    public func setAccentOverride(_ color: Color?) {
        guard palette.accentOverride != nil || color != nil else { return }
        withAnimation(.sumi(.tab)) {
            palette.accentOverride = color
        }
    }

    /// Pins the process appearance to the palette's side. Called from `select`
    /// and once at launch by the app delegate — `AppearanceLock` runs only at
    /// `applicationDidFinishLaunching`, so without the call in `select` a live
    /// switch to Paper leaves every menu and scroller dark.
    @MainActor
    public func applyToNativeChrome() {
        #if os(macOS)
        NSApp?.appearance = nsAppearance
        #endif
    }

    private func refresh() {
        let override = palette.accentOverride
        var next = skin.palette(isLight: appearance.isLight(systemIsDark: Self.systemPrefersDark))
        next.accentOverride = override
        // Assigned unconditionally, including when it resolves to the palette
        // already in force (picking "Follow system" on a Mac already set to
        // Light). That used to be worth guarding because a change rerooted the
        // view tree; now it is one struct assignment that observers compare
        // against what they already drew.
        palette = next
    }

    // MARK: System appearance

    /// Not `NSApp.effectiveAppearance`: the app pins that to its own choice at
    /// launch, so asking it what the system wants returns our own answer back.
    /// The global domain key is what the pin does not touch.
    public static var systemPrefersDark: Bool {
        #if os(macOS)
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        #elseif canImport(UIKit)
        return UITraitCollection.current.userInterfaceStyle == .dark
        #else
        return true
        #endif
    }

    private func observeSystemAppearance() {
        #if os(macOS)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.appearance == .system else { return }
            MainActor.assumeIsolated {
                self.animateToNewPalette()
            }
        }
        #endif
    }
}

// MARK: - Themed root

/// Wraps the app's content so a theme change actually lands.
///
/// Two things happen here that a view reading `SumiTheme.foreground` cannot do
/// for itself: SwiftUI's own environment is told which side we are on
/// (`preferredColorScheme`), and the palette is published for anything that
/// would rather read it than a static.
///
/// It used to carry `.id(themeId)` as well, rebuilding the whole tree on every
/// switch. That was there for colours Observation cannot reach — one resolved
/// into an AppKit layer, captured in a struct-scope `let`, or baked into an
/// `@State` initial value — and the app has none: the only layer colours in it
/// are `MpvSurface`'s black and clear, which no palette touches. What the
/// reroot did have was a cost. A fresh identity discards every `@State` below
/// it, so a theme switch reset every scroll offset and, with a player mounted,
/// tore down the mpv surface — `dismantleNSView` stops playback, so changing
/// theme mid-episode ended the stream. It also made the switch a hard cut:
/// there is no view left to tween from. Keeping the identity is what lets
/// `ThemeStore.select` animate the palette swap instead.
public struct ThemedRoot<Content: View>: View {
    @State private var store = ThemeStore.shared
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .environment(\.sumiPalette, store.palette)
            .preferredColorScheme(store.colorScheme)
    }
}

private struct SumiPaletteKey: EnvironmentKey {
    static let defaultValue: SumiPalette = .ink
}

public extension EnvironmentValues {
    /// The palette in force. Views normally read `SumiTheme.<token>` instead;
    /// this exists for the ones that want to branch on `isLight` or hand a
    /// whole palette to a preview.
    var sumiPalette: SumiPalette {
        get { self[SumiPaletteKey.self] }
        set { self[SumiPaletteKey.self] = newValue }
    }
}
