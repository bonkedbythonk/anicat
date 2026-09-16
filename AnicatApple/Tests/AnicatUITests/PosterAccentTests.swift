import Testing
import Foundation
import CoreGraphics
@testable import AnicatUI

@Suite("Poster accent")
struct PosterAccentTests {
    /// A cover whose colour is decided per pixel, in the RGBA order
    /// CoreGraphics takes for a fixture.
    private func cover(width: Int = 64, height: Int = 96, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let base = (y * width + x) * 4
                bytes[base] = r
                bytes[base + 1] = g
                bytes[base + 2] = b
            }
        }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test("A blue cover with grey shading votes blue")
    func blueCoverVotesBlue() {
        // Two thirds grey and black, the way line art and shading outnumber
        // colour on a real cover; a plain average would be a dark slate.
        let image = cover { x, _ in
            switch x % 3 {
            case 0: return (30, 60, 200)
            case 1: return (90, 90, 90)
            default: return (10, 10, 10)
            }
        }
        let dominant = try! #require(PosterAccent.dominant(in: image))
        #expect(abs(dominant.hue - 229) < 8)
        // The 32x48 collapse averages the grey stripes into the blue ones,
        // which is what a real cover's shading does too.
        #expect(dominant.saturation > 0.5)
    }

    @Test("A red cover's hue is taken on the circle, not as a mean of degrees")
    func redStraddlesZero() {
        // Half at 350 degrees, half at 10: averaged as numbers they land on
        // 180, which is cyan.
        let image = cover { x, _ in
            x % 2 == 0 ? (220, 30, 60) : (220, 60, 30)
        }
        let dominant = try! #require(PosterAccent.dominant(in: image))
        #expect(dominant.hue < 15 || dominant.hue > 345)
    }

    @Test("A monochrome cover keeps the palette's own accent")
    func greyCoverAbstains() {
        let image = cover { x, y in
            let v = UInt8((x + y) % 200 + 20)
            return (v, v, v)
        }
        #expect(PosterAccent.dominant(in: image) == nil)
    }

    @Test("A grey cover with a small logo does not turn the app the logo's colour")
    func smallLogoAbstains() {
        let image = cover { x, y in
            (x < 6 && y < 6) ? (255, 0, 0) : (120, 120, 120)
        }
        #expect(PosterAccent.dominant(in: image) == nil)
    }

    @Test("The accent stays inside the base indigo's brightness band on each side")
    func accentBandsPerSide() {
        let vivid = PosterAccent.Dominant(hue: 120, saturation: 1.0)
        let pale = PosterAccent.Dominant(hue: 120, saturation: 0.1)
        for dominant in [vivid, pale] {
            for isLight in [false, true] {
                let color = PosterAccent.color(for: dominant, isLight: isLight)
                let hsb = PosterAccent.hsb(of: color)
                #expect(abs(hsb.hue - 120) < 2)
                if isLight {
                    #expect(hsb.saturation >= 0.44 && hsb.saturation <= 0.66)
                    #expect(hsb.brightness >= 0.45 && hsb.brightness <= 0.55)
                } else {
                    #expect(hsb.saturation >= 0.29 && hsb.saturation <= 0.43)
                    #expect(hsb.brightness >= 0.83 && hsb.brightness <= 0.85)
                }
            }
        }
    }

    @Test("RGB to HSB")
    func hsbConversion() {
        let (h, s, b) = PosterAccent.hsb(r: 0, g: 1, b: 0)
        #expect(h == 120 && s == 1 && b == 1)
        let grey = PosterAccent.hsb(r: 0.5, g: 0.5, b: 0.5)
        #expect(grey.1 == 0 && grey.2 == 0.5)
    }
}
