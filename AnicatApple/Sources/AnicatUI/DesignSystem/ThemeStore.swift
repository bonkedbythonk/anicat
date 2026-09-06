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

// MARK: - The three palettes

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

    /// Every palette the picker offers, in the order it offers them.
    static let all: [SumiPalette] = [.ink, .paper, .oled]
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
        let channels = [
            Double((int >> 16) & 0xFF) / 255.0,
            Double((int >> 8) & 0xFF) / 255.0,
            Double(int & 0xFF) / 255.0
        ].map { channel -> Double in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
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

/// What the user picked, which is not the same thing as which palette is in
/// force: `system` is a resolution rule.
public enum AnicatTheme: String, CaseIterable, Sendable, Identifiable {
    case ink
    case paper
    case oled
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ink: return "Ink & Index"
        case .paper: return "Paper"
        case .oled: return "OLED"
        case .system: return "Follow system"
        }
    }

    public var caption: String {
        switch self {
        case .ink: return "Warm dark, the original skin"
        case .paper: return "Washi light"
        case .oled: return "True black"
        case .system: return "Paper by day, Ink by night"
        }
    }

    /// The palette this selection means right now. `system` maps light to
    /// Paper and dark to Ink; it never resolves to OLED, which is a panel
    /// choice the OS knows nothing about.
    public func palette(systemIsDark: Bool) -> SumiPalette {
        switch self {
        case .ink: return .ink
        case .paper: return .paper
        case .oled: return .oled
        case .system: return systemIsDark ? .ink : .paper
        }
    }

    /// The swatch the picker draws for this option. `system` borrows whichever
    /// palette it currently resolves to, so the swatch is never a lie.
    public func previewPalette(systemIsDark: Bool) -> SumiPalette {
        palette(systemIsDark: systemIsDark)
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
    public static let defaultsKey = "anicat_theme"

    public private(set) var theme: AnicatTheme
    public private(set) var palette: SumiPalette

    /// Changes on every palette change and is used as `ThemedRoot`'s `.id`.
    /// Observation alone repaints a view whose *body* reads a token, which is
    /// most of them; it does not reach a colour that was resolved into an
    /// AppKit layer, captured in a struct-scope `let`, or baked into an
    /// `@State` initial value. Those only come back with a fresh view tree.
    public private(set) var themeId: Int = 0

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
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let theme = stored.flatMap(AnicatTheme.init(rawValue:)) ?? .ink
        self.theme = theme
        self.palette = theme.palette(systemIsDark: Self.systemPrefersDark)
        observeSystemAppearance()
    }

    @MainActor
    public func select(_ theme: AnicatTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
        refresh()
        applyToNativeChrome()
    }

    /// Sets the app-wide accent, or clears it back to the palette's own.
    /// Nothing calls this yet; it is the poster-accent hook.
    @MainActor
    public func setAccentOverride(_ color: Color?) {
        guard palette.accentOverride != nil || color != nil else { return }
        palette.accentOverride = color
        themeId &+= 1
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
        var next = theme.palette(systemIsDark: Self.systemPrefersDark)
        next.accentOverride = override
        let reroots = next.id != palette.id
        palette = next
        // Only a selection that lands on a different palette bumps the id.
        // Picking "Follow system" on a Mac already set to Light resolves to
        // the Paper that is already in force, and rerooting for that discards
        // every @State below `ThemedRoot` — scroll offsets, and the mpv
        // surface if a player is mounted — to repaint nothing.
        if reroots { themeId &+= 1 }
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
            guard let self, self.theme == .system else { return }
            MainActor.assumeIsolated {
                self.refresh()
                self.applyToNativeChrome()
            }
        }
        #endif
    }
}

// MARK: - Themed root

/// Wraps the app's content so a theme change actually lands.
///
/// Three things happen here that a view reading `SumiTheme.foreground` cannot
/// do for itself: the whole tree is rebuilt (`.id`), SwiftUI's own environment
/// is told which side we are on (`preferredColorScheme`), and the palette is
/// published for anything that would rather read it than a static.
///
/// The rebuild is not free: a fresh identity discards every `@State` below it,
/// which includes scroll offsets and, if a player is mounted, the mpv surface.
/// That is the price of one deliberate switch in Settings, and it is why the
/// id is bumped only by `select` and `setAccentOverride`, never by a repaint.
public struct ThemedRoot<Content: View>: View {
    @State private var store = ThemeStore.shared
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .id(store.themeId)
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
