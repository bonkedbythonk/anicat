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

    public static let bandFraction: CGFloat = 0.2

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
        let bottomCrop = image.cropping(to: CGRect(x: 0, y: h - bh, width: w, height: bh)) ?? image
        let leftCrop = image.cropping(to: CGRect(x: 0, y: 0, width: bw, height: h)) ?? image
        let rightCrop = image.cropping(to: CGRect(x: w - bw, y: 0, width: bw, height: h)) ?? image
        top = Self.collapse(topCrop, to: CGSize(width: w, height: 1)) ?? topCrop
        bottom = Self.collapse(bottomCrop, to: CGSize(width: w, height: 1)) ?? bottomCrop
        left = Self.collapse(leftCrop, to: CGSize(width: 1, height: h)) ?? leftCrop
        right = Self.collapse(rightCrop, to: CGSize(width: 1, height: h)) ?? rightCrop
    }

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
