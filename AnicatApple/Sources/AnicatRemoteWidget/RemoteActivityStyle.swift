import AnicatRemoteActivity
import CoreText
import SwiftUI
import UIKit

/// The app's own look, rebuilt from the palette the activity carries.
///
/// A copy of a handful of tokens rather than a link to `SumiTheme`: the
/// widget must not link AnicatUI, which would drag mpv, FFmpeg and their
/// whole xcframework closure into a process that draws a progress bar. What
/// crosses instead is hex, and this is where it becomes colour and type.
enum SumiWidget {
    static func color(_ hex: String, opacity: Double = 1) -> Color {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard let number = UInt64(value, radix: 16), value.count == 6 else {
            return .primary.opacity(opacity)
        }
        return Color(
            .sRGB,
            red: Double((number & 0xFF0000) >> 16) / 255,
            green: Double((number & 0x00FF00) >> 8) / 255,
            blue: Double(number & 0x0000FF) / 255,
            opacity: opacity
        )
    }

    /// Registers the bundled faces once per process.
    ///
    /// The extension carries its own copies, declared in its own
    /// `UIAppFonts`: a font registered by the app is registered in the app's
    /// process, and the widget is a different one.
    private static let registered: Bool = {
        for file in ["Geist.ttf", "IBMPlexMono-Regular.ttf", "IBMPlexMono-Medium.ttf", "IBMPlexMono-SemiBold.ttf"] {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// The stamped register: episode numbers, clocks, the host name. Falls
    /// back to the system monospace, never to the proportional default --
    /// a timestamp that changes width every second is what this face is for.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registered
        // Matched, not compared: `Font.Weight` is not `Comparable`, and the
        // three faces bundled here are the only ones there is a file for.
        let face: String
        switch weight {
        case .semibold, .bold, .heavy, .black: face = "IBMPlexMono-SemiBold"
        case .medium: face = "IBMPlexMono-Medium"
        default: face = "IBMPlexMono-Regular"
        }
        if UIFont(name: face, size: size) != nil {
            return .custom(face, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func heading(_ size: CGFloat, serif: Bool, weight: Font.Weight = .semibold) -> Font {
        _ = registered
        if serif { return .system(size: size, weight: weight, design: .serif) }
        if UIFont(name: "Geist-Regular", size: size) != nil {
            return .custom("Geist-Regular", size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

extension RemoteActivityAttributes {
    var background: Color { SumiWidget.color(backgroundHex) }
    var card: Color { SumiWidget.color(cardHex) }
    var foreground: Color { SumiWidget.color(foregroundHex) }
    var muted: Color { SumiWidget.color(foregroundHex, opacity: mutedAlpha) }
    var border: Color { SumiWidget.color(foregroundHex, opacity: borderAlpha) }
    var accent: Color { SumiWidget.color(accentHex) }
    /// The track a progress bar sits in, matching the app's `foregroundWash`.
    var wash: Color { SumiWidget.color(foregroundHex, opacity: 0.10) }
}

extension RemoteActivityAttributes.ContentState {
    var elapsedStamp: String { Self.stamp(currentTime) }
    var remainingStamp: String { "-" + Self.stamp(max(duration - currentTime, 0)) }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    static func stamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
