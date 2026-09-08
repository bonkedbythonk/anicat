import Foundation
import SwiftUI
import Accelerate
import CoreGraphics
import ImageIO

/// One thumbnail of the picture, ready to be blurred behind the player.
///
/// `id` is what SwiftUI cross-fades on, not the pixels: two consecutive
/// frames of a static shot are byte-identical, and an `Equatable` that
/// compared images would have to read 9 KB on every diff to conclude the
/// drift should stop.
public struct AmbientFrame: @unchecked Sendable, Equatable, Identifiable {
    public let id: Int
    public let image: CGImage
    /// The outer fifth of the frame on each side. Each letterbox bar is lit
    /// by the band of picture it touches, the way a zoned backlight is: a
    /// single blurred copy of the whole frame mixed the centre into every
    /// bar and the light did not line up with the picture's edges.
    public let top: CGImage
    public let bottom: CGImage
    public let left: CGImage
    public let right: CGImage
    /// The same four bands as colour stops for `AmbientGlowView`'s gradient
    /// layers: `horizontalStops` along the top and bottom bars,
    /// `verticalStops` down the pillars. Fixed counts, whatever the
    /// thumbnail's size: Core Animation only interpolates between colour
    /// arrays of equal length, and the drawable's aspect changes with the
    /// window.
    public let topColors: [CGColor]
    public let bottomColors: [CGColor]
    public let leftColors: [CGColor]
    public let rightColors: [CGColor]

    public static let bandFraction: CGFloat = 0.2
    /// 32 stops across a bar: about 60 pt apart on a 1920 pt screen, which
    /// with the linear interpolation between stops is as soft as the 36 pt
    /// blur the image version used, without the blur.
    public static let horizontalStops = 32
    public static let verticalStops = 18

    public init(id: Int, image: CGImage) {
        self.id = id
        self.image = image
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let bw = max(1, (w * Self.bandFraction).rounded()), bh = max(1, (h * Self.bandFraction).rounded())
        // Each band is collapsed to one pixel across its thin axis, so a
        // top band is 64x1: one colour per column, like the LEDs behind a
        // TV. A 64x7 band stretched over a 110 pt bar showed its seven
        // source rows as horizontal stripes through the blur.
        let topCrop = image.cropping(to: CGRect(x: 0, y: 0, width: w, height: bh)) ?? image
        // The bottom band is taken from just above the subtitle zone, the
        // rows 12% to 22% up from the edge, rather than the edge itself:
        // the drawable carries the rendered subtitles, and white text
        // popping in and out of the bottom fifth was the remaining
        // "flicker" once the sampling itself was smooth.
        let subtitleZone = (h * 0.12).rounded()
        let bottomCrop = image.cropping(to: CGRect(x: 0, y: h - subtitleZone - bh / 2, width: w, height: bh / 2)) ?? image
        let leftCrop = image.cropping(to: CGRect(x: 0, y: 0, width: bw, height: h)) ?? image
        let rightCrop = image.cropping(to: CGRect(x: w - bw, y: 0, width: bw, height: h)) ?? image
        top = Self.collapse(topCrop, to: CGSize(width: w, height: 1)) ?? topCrop
        bottom = Self.collapse(bottomCrop, to: CGSize(width: w, height: 1)) ?? bottomCrop
        left = Self.collapse(leftCrop, to: CGSize(width: 1, height: h)) ?? leftCrop
        right = Self.collapse(rightCrop, to: CGSize(width: 1, height: h)) ?? rightCrop
        topColors = Self.stops(of: topCrop, count: Self.horizontalStops, horizontal: true)
        bottomColors = Self.stops(of: bottomCrop, count: Self.horizontalStops, horizontal: true)
        leftColors = Self.stops(of: leftCrop, count: Self.verticalStops, horizontal: false)
        rightColors = Self.stops(of: rightCrop, count: Self.verticalStops, horizontal: false)
    }

    /// `count` colours along `image`, each the mean of its slice, then a
    /// 1-2-1 smoothing across neighbours and a little more saturation and
    /// a little less brightness, the grading the blurred version applied
    /// with view modifiers. The smoothing is what a blur did for a hard
    /// edge in the picture: without it a bright sleeve against a dark wall
    /// put a visible kink in the bar where two adjacent stops differ.
    static func stops(of image: CGImage, count: Int, horizontal: Bool) -> [CGColor] {
        let size = horizontal ? CGSize(width: count, height: 1) : CGSize(width: 1, height: count)
        guard let strip = collapse(image, to: size),
              let data = strip.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return Array(repeating: CGColor(gray: 0, alpha: 1), count: count) }
        let stride = strip.bytesPerRow
        // `collapse` draws noneSkipFirst little-endian: B, G, R, X in memory.
        var raw: [(r: Float, g: Float, b: Float)] = (0..<count).map { i in
            let offset = horizontal ? i * 4 : i * stride
            return (Float(bytes[offset + 2]) / 255, Float(bytes[offset + 1]) / 255, Float(bytes[offset]) / 255)
        }
        if count >= 3 {
            let source = raw
            // Clamped at the ends rather than skipping them. Running this
            // over 1..<count-1 left the first and last stop ungraded, so
            // every bar could still end on a hard step even once the
            // interior was smooth.
            for i in 0..<count {
                let prev = source[max(0, i - 1)]
                let next = source[min(count - 1, i + 1)]
                raw[i] = (
                    (prev.r + 2 * source[i].r + next.r) / 4,
                    (prev.g + 2 * source[i].g + next.g) / 4,
                    (prev.b + 2 * source[i].b + next.b) / 4
                )
            }
        }

        // The bar's own average, which is what a dark stop is filled toward
        // and what the floor below is measured against. Both are relative to
        // this rather than absolute: a dark scene should dim the whole bar,
        // not punch holes in it.
        let n = Float(count)
        let mean = (
            r: raw.reduce(0) { $0 + $1.r } / n,
            g: raw.reduce(0) { $0 + $1.g } / n,
            b: raw.reduce(0) { $0 + $1.b } / n
        )
        let meanLuma = Self.luma(mean.r, mean.g, mean.b)
        let floorLuma = meanLuma * Self.ambientFloor

        return raw.map { pixel in
            // Pulled toward the bar's average before anything else. A mean
            // per slice on its own is spotty by construction -- one dark
            // object at the edge of the picture is a black notch in a lit
            // bar -- and this is the fill every ambient-light system applies
            // for the same reason. Partial, so the left half can still be a
            // different colour from the right.
            let f = Self.ambientFill
            var r = pixel.r + (mean.r - pixel.r) * f
            var g = pixel.g + (mean.g - pixel.g) * f
            var b = pixel.b + (mean.b - pixel.b) * f

            // Saturation around this stop's own luma, as before. The flat
            // -0.05 that used to follow is gone: it crushed any stop already
            // near black to exactly black, which is what put the holes in.
            let l = Self.luma(r, g, b)
            r = l + (r - l) * 1.2
            g = l + (g - l) * 1.2
            b = l + (b - l) * 1.2

            // Lift to the floor by scaling, which keeps the hue: a dim blue
            // stop becomes a brighter blue, not a grey one. A stop with no
            // colour at all to scale takes the bar's average instead, since
            // multiplying black by anything is still black.
            let lit = Self.luma(r, g, b)
            if lit < floorLuma {
                if lit > 0.001 {
                    let k = floorLuma / lit
                    r *= k; g *= k; b *= k
                } else if meanLuma > 0.001 {
                    let k = floorLuma / meanLuma
                    r = mean.r * k; g = mean.g * k; b = mean.b * k
                }
            }

            func clamp(_ c: Float) -> CGFloat { CGFloat(min(1, max(0, c))) }
            return CGColor(srgbRed: clamp(r), green: clamp(g), blue: clamp(b), alpha: 1)
        }
    }

    static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// How far a stop is pulled toward the bar's average. Enough to close a
    /// hole, not so much that the bar becomes one colour.
    static let ambientFill: Float = 0.30

    /// The dimmest a stop may be, as a fraction of the bar's own average.
    /// Relative on purpose: an absolute floor lights a bar under a black
    /// frame, and the glow is supposed to follow the picture.
    static let ambientFloor: Float = 0.35

    /// Draws `image` scaled into `size` with averaging interpolation, which
    /// for a one-pixel-thin target is the mean across the collapsed axis.
    static func collapse(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func == (lhs: AmbientFrame, rhs: AmbientFrame) -> Bool {
        lhs.id == rhs.id
    }
}

/// The self-disable rule around `screenshot-raw`, kept as a value so the
/// interval, the budget and the strike policy can be exercised without a
/// running player.
public struct AmbientSampleGate: Sendable, Equatable {
    /// How often a frame is sampled when the machine keeps up: 50 ms,
    /// twenty a second, under a 0.15 s fade in the view. Ten a second still
    /// read as delayed; a steady-state sample measured 5 ms, so twenty a
    /// second is a tenth of a core on mpv's lock, and the budget below
    /// backs it off on a machine that cannot afford that.
    public static let interval: CFAbsoluteTime = 0.05
    /// The slowest the gate backs off to, 0.4 s: still a live picture, just
    /// a lazier one; the previous rule stopped sampling altogether after
    /// three slow samples and left the bars frozen on the episode still,
    /// which read as "the glow is stuck".
    public static let maxInterval: CFAbsoluteTime = 0.4
    /// `screenshot-raw` runs on mpv's core lock, so a slow sample is a
    /// dropped frame. Covers the downscale too. 30 ms rather than 15: a
    /// 1080p frame conversion alone lands near 15 on a busy core, and one
    /// dropped frame every so often costs less than a frozen glow.
    public static let budget: CFAbsoluteTime = 0.030
    /// Slow samples in a row before the interval doubles.
    public static let slowSampleLimit = 3
    /// Fast samples in a row before the interval halves back. Five, not
    /// twenty: launch is the slow moment (the engine, the image cache and
    /// the first decode all land together, samples of 60 ms), and twenty
    /// samples at the backed-off rate meant most of a minute at the slower
    /// cadence after a two-second startup.
    public static let recoverySampleLimit = 5

    public private(set) var gaveUp = false
    public private(set) var currentInterval: CFAbsoluteTime = AmbientSampleGate.interval
    private var lastSampleAt: CFAbsoluteTime = 0
    private var consecutiveSlowSamples = 0
    private var consecutiveFastSamples = 0

    public init() {}

    public func isDue(at now: CFAbsoluteTime) -> Bool {
        // A millisecond of slack: (100 + 0.1) - 100 is 0.0999 in binary
        // floating point, which held a sample due exactly on the interval.
        !gaveUp && now - lastSampleAt >= currentInterval - 0.001
    }

    /// Claims the slot for a sample about to run.
    public mutating func begin(at now: CFAbsoluteTime) {
        lastSampleAt = now
    }

    /// Records how long a sample took and adapts the interval: three slow
    /// in a row double it (to at most `maxInterval`), twenty fast in a row
    /// halve it back. Always returns true; only `giveUp` stops sampling.
    @discardableResult
    public mutating func record(elapsed: CFAbsoluteTime) -> Bool {
        if elapsed > Self.budget {
            consecutiveFastSamples = 0
            consecutiveSlowSamples += 1
            if consecutiveSlowSamples >= Self.slowSampleLimit {
                consecutiveSlowSamples = 0
                currentInterval = min(Self.maxInterval, currentInterval * 2)
            }
        } else {
            consecutiveSlowSamples = 0
            consecutiveFastSamples += 1
            if consecutiveFastSamples >= Self.recoverySampleLimit, currentInterval > Self.interval {
                consecutiveFastSamples = 0
                currentInterval = max(Self.interval, currentInterval / 2)
            }
        }
        return true
    }

    /// Unsupported outright, rather than slow.
    public mutating func giveUp() {
        gaveUp = true
    }

    /// Only for the log line that reports a slow sample.
    public var slowStreak: Int { consecutiveSlowSamples }
}

public enum AmbientGlow {
    /// How mpv's `screenshot-raw` laid the frame out in memory, as the
    /// `CGImage` flags that read it back the same way. The command documents
    /// the format as a field rather than a guarantee, and reading it the
    /// wrong way round tints the whole app.
    ///
    /// Both are `noneSkip*`, never a `premultiplied*` variant: mpv's fourth
    /// byte is a literal 0, so any alpha-carrying variant draws the entire
    /// glow fully transparent, with no error raised anywhere to say so.
    public struct PixelOrder: Sendable, Equatable {
        public let bitmapInfo: CGBitmapInfo

        /// Bytes B, G, R, X — an XRGB word read little-endian.
        public static let bgr0 = PixelOrder(
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                .union(.byteOrder32Little)
        )
        /// Bytes R, G, B, X, which is the default byte order already.
        public static let rgb0 = PixelOrder(
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        )

        public static func named(_ format: String) -> PixelOrder? {
            switch format.lowercased() {
            case "bgr0", "bgra": return .bgr0
            case "rgb0", "rgba": return .rgb0
            default: return nil
            }
        }
    }

    /// The long side of the thumbnail everything is drawn from. 64 is
    /// already more detail than survives a 60pt blur; the point of the
    /// downscale is that the layer SwiftUI blurs is a few kilobytes rather
    /// than the 8 MB frame `screenshot-raw` handed over.
    public static let maxSide = 64

    /// How many source rows each row of the thumbnail is allowed to be
    /// averaged from before the rest are skipped outright. Eight is well
    /// past the point where more rows change a 64px thumbnail that is about
    /// to be blurred at 60pt.
    static let sourceRowsPerDestinationRow = 8

    /// The thumbnail's dimensions for a frame of `width` x `height`, aspect
    /// preserved, long side clamped to `maxSide`. A frame already smaller
    /// than that is not scaled up.
    public static func thumbnailSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let longest = max(width, height)
        guard longest > maxSide else { return (width, height) }
        let scale = Double(maxSide) / Double(longest)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// Downscales a packed 32-bit frame to at most `maxSide` on the long
    /// side and hands it back as a `CGImage`.
    ///
    /// vImage rather than a hand-rolled sampler: a box filter written in
    /// Swift has to touch the same 8 MB with bounds checks and no vector
    /// unit, and the earlier scattered-sample version of this file traded
    /// that cost for visible aliasing — 4096 point samples of a 1080p frame
    /// is one pixel in 500, so a moving picture made the result flicker.
    /// `vImageScale_ARGB8888` is channel-agnostic, so the byte order is not
    /// its problem: it is carried through untouched and named to `CGImage`.
    public static func thumbnail(
        bytes: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        stride: Int,
        order: PixelOrder
    ) -> CGImage? {
        guard let size = thumbnailSize(width: width, height: height), stride >= width * 4 else { return nil }
        // Rows are decimated before vImage sees them, by handing it a stride
        // `rowStep` times the real one and a proportionally shorter buffer.
        // The whole cost of this call is reading the source frame, so
        // dropping rows it would only have averaged away is nearly free:
        // measured on this machine, 1080p 2.41ms -> 0.65ms and 4K
        // 9.78ms -> 1.08ms. The 4K figure is the reason it exists — at
        // 9.78ms plus the screenshot itself, every sample overran the 15ms
        // budget and the feature disabled itself three seconds in.
        let rowStep = max(1, height / (size.height * Self.sourceRowsPerDestinationRow))
        var source = vImage_Buffer(
            data: bytes,
            height: vImagePixelCount(height / rowStep),
            width: vImagePixelCount(width),
            rowBytes: stride * rowStep
        )
        let destinationRowBytes = size.width * 4
        var scaled = Data(count: destinationRowBytes * size.height)
        let ok = scaled.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var destination = vImage_Buffer(
                data: base,
                height: vImagePixelCount(size.height),
                width: vImagePixelCount(size.width),
                rowBytes: destinationRowBytes
            )
            return vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok, let provider = CGDataProvider(data: scaled as CFData) else { return nil }
        return CGImage(
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: destinationRowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: order.bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// The fallback source: the episode's own still, at the same size a
    /// sampled frame arrives at, so there is one drawing path rather than
    /// two. Always fetched, whether or not frame sampling turns out to be
    /// available, so the glow is up before the first frame has decoded.
    public static func still(from url: URL) async -> CGImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ] as CFDictionary)
    }
}

/// How much of mpv's video rect is black bar *encoded into the frame*,
/// as a fraction of that rect on each side.
///
/// Anime does this constantly and the container never says so: the Grisaia
/// BD encode is 1920x1080, 16:9, sample aspect 1:1 by every property mpv
/// reports, and its cold open is a 1920x819 picture with 130 black rows
/// above and 131 below burned into the frame. mpv fits 16:9 into the
/// window, so nothing is letterboxed as far as the geometry is concerned,
/// `AmbientMetalSampler` skipped the sample outright ("no bars, nothing to
/// light"), and the widest scenes in a show were the ones with no glow at
/// all.
public struct AmbientContentInset: Sendable, Equatable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public static let zero = AmbientContentInset(top: 0, bottom: 0, left: 0, right: 0)

    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public var isZero: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }

    /// `rect` with the bars taken off. Used on the video rect the chrome
    /// already computes, rather than in drawable pixels, so nothing here
    /// has to know about backing scale or where mpv centres the picture.
    public func apply(to rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + rect.width * left,
            y: rect.minY + rect.height * top,
            width: max(0, rect.width * (1 - left - right)),
            height: max(0, rect.height * (1 - top - bottom))
        )
    }
}

extension AmbientGlow {
    /// A row or column counts as bar when every colour byte across it is at
    /// or under this. Not zero: the thumbnail is a bilinear downscale of a
    /// 10-bit source, so a bar row lands a few levels above black, and the
    /// smoothing in the sampler drags it further while a scene changes.
    static let barLevel: UInt8 = 12
    /// Never take more than this off one side. A fade to black is every
    /// side at once, and without the cap the glow rect collapsed to nothing
    /// mid-fade and snapped back open on the next shot.
    static let maxInsetFraction = 0.4
    /// How much brighter than a bar the picture past the boundary row has
    /// to be before that row's level is read as a blend. Under this the
    /// two are too close to tell apart and the whole row is kept as
    /// picture, which errs towards a hairline rather than towards glow
    /// drawn over the frame.
    static let minimumBoundaryContrast = 40.0

    /// The bars burned into `bytes`, a packed 32-bit thumbnail, as
    /// fractions of it. `nil` when the picture is too dark to tell — a
    /// fade, a black frame between cuts — so the caller can hold the inset
    /// it already had instead of pulsing the bands open and shut.
    ///
    /// Byte order does not matter: black is zero in every channel, and the
    /// fourth byte of both orders this app sees is the padding one.
    public static func contentInset(
        bytes: [UInt8],
        width: Int,
        height: Int,
        stride: Int
    ) -> AmbientContentInset? {
        guard width > 0, height > 0, bytes.count >= stride * height, stride >= width * 4 else { return nil }
        func rowIsBar(_ y: Int) -> Bool {
            let base = y * stride
            for x in 0..<width {
                let p = base + x * 4
                if bytes[p] > barLevel || bytes[p + 1] > barLevel || bytes[p + 2] > barLevel { return false }
            }
            return true
        }
        func columnIsBar(_ x: Int) -> Bool {
            let p0 = x * 4
            for y in 0..<height {
                let p = y * stride + p0
                if bytes[p] > barLevel || bytes[p + 1] > barLevel || bytes[p + 2] > barLevel { return false }
            }
            return true
        }
        func rowLevel(_ y: Int) -> Double {
            let base = y * stride
            var total = 0
            for x in 0..<width {
                let p = base + x * 4
                total += Int(max(bytes[p], max(bytes[p + 1], bytes[p + 2])))
            }
            return Double(total) / Double(width)
        }
        func columnLevel(_ x: Int) -> Double {
            let p0 = x * 4
            var total = 0
            for y in 0..<height {
                let p = y * stride + p0
                total += Int(max(bytes[p], max(bytes[p + 1], bytes[p + 2])))
            }
            return Double(total) / Double(height)
        }
        // Capped before the scan rather than after: a fade reads as bar all
        // the way across, and a loop that walked the whole axis first would
        // report top and bottom meeting in the middle.
        let maxRows = Int(Double(height) * maxInsetFraction)
        let maxColumns = Int(Double(width) * maxInsetFraction)
        var top = 0
        while top < maxRows, rowIsBar(top) { top += 1 }
        var bottom = 0
        while bottom < maxRows, rowIsBar(height - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < maxColumns, columnIsBar(left) { left += 1 }
        var right = 0
        while right < maxColumns, columnIsBar(width - 1 - right) { right += 1 }
        // Both ends of an axis hitting the cap is the fade case, not a
        // 5:1 picture: report nothing rather than a bogus inset.
        if maxRows > 0, top == maxRows, bottom == maxRows { return nil }
        if maxColumns > 0, left == maxColumns, right == maxColumns { return nil }
        return AmbientContentInset(
            top: refined(top, of: height, level: { rowLevel($0) }) / Double(height),
            bottom: refined(bottom, of: height, level: { rowLevel(height - 1 - $0) }) / Double(height),
            left: refined(left, of: width, level: { columnLevel($0) }) / Double(width),
            right: refined(right, of: width, level: { columnLevel(width - 1 - $0) }) / Double(width)
        )
    }

    /// `lines` whole bar lines plus however much of the next one was bar
    /// too, `level` reading the i-th line in from that edge.
    ///
    /// The scan can only count whole lines of a 64-wide thumbnail, and the
    /// line the picture's edge falls in is a bilinear blend of bar and
    /// picture, so it never passes the bar test and the band stopped short
    /// of the picture: 16 px of black between the glow and the frame on an
    /// 1898 px window, 0.111 detected against a true 0.120 on the Grisaia
    /// cold open. The blend is linear, so that line's own level says how
    /// much of it was bar.
    static func refined(_ lines: Int, of count: Int, level: (Int) -> Double) -> Double {
        guard lines > 0, lines + 1 < count else { return Double(lines) }
        let boundary = level(lines), picture = level(lines + 1), bar = Double(barLevel)
        guard picture - bar > minimumBoundaryContrast else { return Double(lines) }
        return Double(lines) + min(1, max(0, (picture - boundary) / (picture - bar)))
    }
}

extension AmbientGlow {
    /// `contentInset` for a thumbnail that only exists as a `CGImage` — the
    /// `screenshot-raw` fallback path, which never has the pixels in hand
    /// the way the Metal sampler does. The redraw normalises byte order and
    /// row padding; at 64 px on the long side it costs nothing worth
    /// measuring next to the screenshot that produced the image.
    public static func contentInset(of image: CGImage) -> AmbientContentInset? {
        guard let strip = AmbientFrame.collapse(image, to: CGSize(width: image.width, height: image.height)),
              let data = strip.dataProvider?.data,
              let base = CFDataGetBytePtr(data)
        else { return nil }
        let stride = strip.bytesPerRow
        let bytes = [UInt8](UnsafeBufferPointer(start: base, count: stride * strip.height))
        return contentInset(bytes: bytes, width: strip.width, height: strip.height, stride: stride)
    }
}
