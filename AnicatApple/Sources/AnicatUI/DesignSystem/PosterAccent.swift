import SwiftUI
import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Derives the app accent from the cover that is open.
///
/// The accent is a hue taken from the poster, not a colour lifted off it:
/// a poster's dominant pixel is a wall of navy, a skin tone or a night sky,
/// and any of those painted straight onto a resume pill is either invisible
/// against Ink or reads as an error against Paper. So the poster picks only
/// the hue, and the palette side (light or dark) fixes saturation and
/// brightness to the same band the base indigo sits in, which is what keeps
/// the pill, the tab underline and the sidebar tick readable on every skin.
public enum PosterAccent {
    /// The hue vote a cover cast, in degrees, with the mean saturation of
    /// the pixels that voted for it.
    public struct Dominant: Equatable, Sendable {
        public var hue: Double
        public var saturation: Double
    }

    /// The cover is read at this size. 1536 pixels is enough for a hue vote
    /// and small enough that the pass is under a millisecond; the decode to
    /// get here is the cost, and the image cache has usually paid it for the
    /// compact header already.
    static let sampleSize = CGSize(width: 32, height: 48)

    /// Pixels below this saturation do not vote: they are black outlines,
    /// white paper and grey shading, which together outnumber a poster's
    /// actual colour on most covers, so a plain average lands on mud.
    static let minimumSaturation = 0.25
    /// Pixels this dark do not vote either. Line art and shadow carry a hue
    /// the eye never sees, and on a dark cover they are most of the image.
    static let minimumBrightness = 0.18
    /// Below this share of voting weight the cover is monochrome, and the
    /// palette's own accent stays: a grey manga cover with a red logo would
    /// otherwise turn the whole app red on the strength of forty pixels.
    static let minimumVoteShare = 0.04

    /// 15 degree bins. Coarser and blue and violet share a bin; finer and a
    /// poster's one colour, shaded across a gradient, splits its vote.
    static let hueBins = 24

    /// The hue vote of a decoded cover, or nil when the cover has no colour
    /// worth following.
    public static func dominant(in image: CGImage) -> Dominant? {
        guard let small = AmbientFrame.collapse(image, to: sampleSize),
              let data = small.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let width = small.width, height = small.height, stride = small.bytesPerRow

        // Weight per bin, plus the unit vector sum so the mean hue is taken
        // on the circle: averaging degrees puts a red cover (350 and 10)
        // at 180, which is cyan.
        var weight = [Double](repeating: 0, count: hueBins)
        var sinSum = [Double](repeating: 0, count: hueBins)
        var cosSum = [Double](repeating: 0, count: hueBins)
        var satSum = [Double](repeating: 0, count: hueBins)
        var total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                // `collapse` draws with `byteOrder32Little` + `noneSkipFirst`,
                // which lays a pixel down as B G R X.
                let base = y * stride + x * 4
                let b = Double(bytes[base]) / 255
                let g = Double(bytes[base + 1]) / 255
                let r = Double(bytes[base + 2]) / 255
                let (hue, saturation, brightness) = hsb(r: r, g: g, b: b)
                guard saturation >= minimumSaturation, brightness >= minimumBrightness else { continue }
                // Saturated and bright pixels are the ones the eye reads as
                // "the colour of this poster"; a dim saturated pixel is a
                // shadow of it and gets a smaller say.
                let w = saturation * brightness
                let bin = min(hueBins - 1, Int(hue / 360 * Double(hueBins)))
                let radians = hue * .pi / 180
                weight[bin] += w
                sinSum[bin] += sin(radians) * w
                cosSum[bin] += cos(radians) * w
                satSum[bin] += saturation * w
                total += w
            }
        }
        guard total >= Double(width * height) * minimumVoteShare else { return nil }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }) else { return nil }

        // The winning bin and its two neighbours: a colour shaded across a
        // gradient straddles a bin edge, and taking one bin alone picks the
        // edge rather than the middle.
        var s = 0.0, c = 0.0, sat = 0.0, w = 0.0
        for offset in -1...1 {
            let bin = (best + offset + hueBins) % hueBins
            s += sinSum[bin]; c += cosSum[bin]; sat += satSum[bin]; w += weight[bin]
        }
        guard w > 0 else { return nil }
        var hue = atan2(s, c) * 180 / .pi
        if hue < 0 { hue += 360 }
        return Dominant(hue: hue, saturation: sat / w)
    }

    /// The accent to paint for a hue vote on the given palette side.
    ///
    /// Brightness is fixed per side rather than taken from the poster: the
    /// base indigo is `#8FB8DC` (0.86 bright, 0.35 saturated) on Ink and
    /// `#2F5A76` (0.46 bright, 0.60 saturated) on Paper, and an accent that
    /// wanders off those lands either on white text with no contrast or on
    /// a dark blob against a dark ground. Saturation follows the poster
    /// inside a band around the base value, so a pastel cover gives a
    /// softer accent and a neon one a louder, and neither can go grey.
    public static func color(for dominant: Dominant, isLight: Bool) -> Color {
        // A narrow band on the dark side. At 0.35 to 0.60 a warm cover's
        // pill came out a salmon that sat on the page like a warning, next
        // to a Start Over button that had not changed; the base indigo is
        // 0.35 and the pill is one tone among the chrome, not the loudest
        // thing on it.
        let saturation = isLight
            ? min(0.65, max(0.45, dominant.saturation))
            : min(0.42, max(0.30, dominant.saturation))
        // Yellow and cyan are perceptually far lighter than blue and violet
        // at equal HSB brightness; pulled down a step on the light side so a
        // yellow accent is not a pale wash on Paper, and left alone on the
        // dark side where a bright yellow is what reads.
        let luminous = (dominant.hue > 40 && dominant.hue < 200)
        let brightness = isLight ? (luminous ? 0.46 : 0.54) : 0.84
        return Color(hue: dominant.hue / 360, saturation: saturation, brightness: brightness)
    }

    /// The accent for a decoded cover, or nil when the palette's own should
    /// stay.
    public static func accent(for image: CGImage, isLight: Bool) -> Color? {
        dominant(in: image).map { color(for: $0, isLight: isLight) }
    }

    // MARK: Colour space

    /// The HSB of a resolved colour, for checking what `color(for:)` painted.
    static func hsb(of color: Color) -> (hue: Double, saturation: Double, brightness: Double) {
        #if os(macOS)
        let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return hsb(r: native.redComponent, g: native.greenComponent, b: native.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return hsb(r: r, g: g, b: b)
        #endif
    }

    /// RGB to hue (degrees), saturation and brightness, HSB as `Color(hue:)`
    /// takes it.
    static func hsb(r: Double, g: Double, b: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        let brightness = maxC
        let saturation = maxC == 0 ? 0 : delta / maxC
        guard delta > 0 else { return (0, 0, brightness) }
        var hue: Double
        if maxC == r {
            hue = (g - b) / delta
        } else if maxC == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, brightness)
    }
}
