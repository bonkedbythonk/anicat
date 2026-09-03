import SwiftUI

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
    public static var background: Color {
        Color(
            nsColorOrUIColor(
                darkHex: "#161310",
                lightHex: "#F1ECE2"
            )
        )
    }
    
    /// Card Ink (Dark #1E1A15) / Light Card (#FAF7F0)
    public static var card: Color {
        Color(
            nsColorOrUIColor(
                darkHex: "#1E1A15",
                lightHex: "#FAF7F0"
            )
        )
    }
    
    /// Primary Foreground Text (#EDE7DC dark / #26221B light)
    public static var foreground: Color {
        Color(
            nsColorOrUIColor(
                darkHex: "#EDE7DC",
                lightHex: "#26221B"
            )
        )
    }
    
    /// Muted Text (55% alpha dark / 65% alpha light)
    public static var muted: Color {
        Color(
            nsColorOrUIColor(
                darkHex: "#EDE7DC",
                lightHex: "#26221B",
                darkAlpha: 0.55,
                lightAlpha: 0.65
            )
        )
    }
    
    /// Hairline Border (10% alpha dark / 12% alpha light)
    public static var border: Color {
        Color(
            nsColorOrUIColor(
                darkHex: "#EDE7DC",
                lightHex: "#26221B",
                darkAlpha: 0.10,
                lightAlpha: 0.12
            )
        )
    }
    
    /// The Single Accent: Aizome Indigo (#8FB8DC dark / #33617F light)
    public static var indigo: Color {
        Color(
            nsColorOrUIColor(
                darkHex: "#8FB8DC",
                lightHex: "#33617F"
            )
        )
    }
    
    public static let indigoLight = Color(hex: "#A8C9E6")
    
    // Status Colors (Shared across themes)
    public static let danger = Color(hex: "#EF4444")
    public static let dangerLight = Color(hex: "#F87171")
    public static let success = Color(hex: "#22C55E")
    public static let successLight = Color(hex: "#4ADE80")
    public static let warning = Color(hex: "#EAB308")
    public static let warningLight = Color(hex: "#FACC15")
    
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

public struct SumiTabularMono: ViewModifier {
    var size: CGFloat = 11.5
    var weight: Font.Weight = .regular

    public func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight, design: .monospaced))
            .monospacedDigit()
            .tracking(0.8)
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
