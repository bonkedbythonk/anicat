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
    // MARK: - Colors (Adaptive Dark / Light)
    
    /// Sumi Ink (Dark #161310) / Washi Paper (Light #F1ECE2)
    /// `let` not `var`: the underlying NSColor is itself dynamic (resolves per-appearance
    /// at draw time via nsColorOrUIColor's closure), so caching it doesn't break theme
    /// switching — it just stops every card/row in a scrolling grid from re-allocating
    /// a fresh dynamic NSColor on every access.
    public static let background: Color = Color(
        nsColorOrUIColor(
            darkHex: "#161310",
            lightHex: "#F1ECE2"
        )
    )

    /// Card Ink (Dark #1E1A15) / Light Card (#FAF7F0)
    public static let card: Color = Color(
        nsColorOrUIColor(
            darkHex: "#1E1A15",
            lightHex: "#FAF7F0"
        )
    )

    // index.css defines `--card-color` and `--surface-color` as two separate
    // tokens that happen to share a value in every skin. Keeping both names
    // here (instead of collapsing call sites onto `card`) means a call site
    // ported from the web keeps the name it had there, so a future skin that
    // actually splits the two values only has to change this one line.
    public static var surface: Color { card }

    /// Primary Foreground Text (#EDE7DC dark / #26221B light)
    public static let foreground: Color = Color(
        nsColorOrUIColor(
            darkHex: "#EDE7DC",
            lightHex: "#26221B"
        )
    )

    /// Muted Text (55% alpha dark / 65% alpha light)
    public static let muted: Color = Color(
        nsColorOrUIColor(
            darkHex: "#EDE7DC",
            lightHex: "#26221B",
            darkAlpha: 0.55,
            lightAlpha: 0.65
        )
    )

    /// Hairline Border (10% alpha dark / 12% alpha light)
    public static let border: Color = Color(
        nsColorOrUIColor(
            darkHex: "#EDE7DC",
            lightHex: "#26221B",
            darkAlpha: 0.10,
            lightAlpha: 0.12
        )
    )

    /// The Single Accent: Aizome Indigo (#8FB8DC dark / #33617F light)
    public static let indigo: Color = Color(
        nsColorOrUIColor(
            darkHex: "#8FB8DC",
            lightHex: "#33617F"
        )
    )

    public static let indigoLight = Color(hex: "#A8C9E6")
    
    // Status Colors (Shared across themes)
    public static let danger = Color(hex: "#EF4444")
    public static let dangerLight = Color(hex: "#F87171")
    public static let success = Color(hex: "#22C55E")
    public static let successLight = Color(hex: "#4ADE80")
    public static let warning = Color(hex: "#EAB308")
    public static let warningLight = Color(hex: "#FACC15")
    
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
    
    // MARK: - Dynamic Color Helper
    #if os(macOS)
    private static func nsColorOrUIColor(
        darkHex: String,
        lightHex: String,
        darkAlpha: Double = 1.0,
        lightAlpha: Double = 1.0
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? darkHex : lightHex
            let alpha = isDark ? darkAlpha : lightAlpha
            return nsColorFromHex(hex, alpha: alpha)
        }
    }
    
    private static func nsColorFromHex(_ hex: String, alpha: Double) -> NSColor {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        return NSColor(
            srgbRed: CGFloat((int >> 16) & 0xFF) / 255.0,
            green: CGFloat((int >> 8) & 0xFF) / 255.0,
            blue: CGFloat(int & 0xFF) / 255.0,
            alpha: CGFloat(alpha)
        )
    }
    #else
    private static func nsColorOrUIColor(
        darkHex: String,
        lightHex: String,
        darkAlpha: Double = 1.0,
        lightAlpha: Double = 1.0
    ) -> UIColor {
        UIColor { traitCollection in
            let isDark = traitCollection.userInterfaceStyle == .dark
            let hex = isDark ? darkHex : lightHex
            let alpha = isDark ? darkAlpha : lightAlpha
            return uiColorFromHex(hex, alpha: alpha)
        }
    }
    
    private static func uiColorFromHex(_ hex: String, alpha: Double) -> UIColor {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        return UIColor(
            red: CGFloat((int >> 16) & 0xFF) / 255.0,
            green: CGFloat((int >> 8) & 0xFF) / 255.0,
            blue: CGFloat(int & 0xFF) / 255.0,
            alpha: CGFloat(alpha)
        )
    }
    #endif
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

public struct SumiTabularMono: ViewModifier {
    var size: CGFloat = 11.5
    var weight: Font.Weight = .regular

    public func body(content: Content) -> some View {
        content
            .font(.sumiMono(size: size, weight: weight))
            .monospacedDigit()
            .textCase(.uppercase)
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
    /// Refined, organic spring for pills and indicators: fast with subtle, natural settling.
    static var sumiSpring: Animation {
        .spring(response: 0.30, dampingFraction: 0.82)
    }
}


