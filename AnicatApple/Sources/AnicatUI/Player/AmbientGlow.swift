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

    public init(id: Int, image: CGImage) {
        self.id = id
        self.image = image
    }

    public static func == (lhs: AmbientFrame, rhs: AmbientFrame) -> Bool {
        lhs.id == rhs.id
    }
}

/// The self-disable rule around `screenshot-raw`, kept as a value so the
/// interval, the budget and the strike policy can be exercised without a
/// running player.
public struct AmbientSampleGate: Sendable, Equatable {
    /// How often a frame is sampled. 150 ms, about seven a second, under a
    /// 0.35 s fade in the view: one a second lagged cuts by up to a second
    /// and read as "too slow". The idle tick that drives it is 50 ms, and
    /// the downscale measured 0.65 ms for 1080p, so seven a second is
    /// under 5 ms of work a second before `screenshot-raw` itself.
    public static let interval: CFAbsoluteTime = 0.15
    /// `screenshot-raw` runs on mpv's core lock, so a slow sample is a
    /// dropped frame. Covers the downscale too — both happen before the
    /// event loop gets back to `mpv_wait_event`.
    public static let budget: CFAbsoluteTime = 0.015
    /// Strikes are consecutive, not cumulative: at one sample a second a
    /// cumulative counter kills the feature after three unlucky moments
    /// anywhere in an episode — a seek, a cache stall, a scheduling spike —
    /// and never lets it back. Three in a row is the machine being too slow.
    public static let slowSampleLimit = 3

    public private(set) var gaveUp = false
    private var lastSampleAt: CFAbsoluteTime = 0
    private var consecutiveSlowSamples = 0

    public init() {}

    public func isDue(at now: CFAbsoluteTime) -> Bool {
        !gaveUp && now - lastSampleAt >= Self.interval
    }

    /// Claims the slot for a sample about to run.
    public mutating func begin(at now: CFAbsoluteTime) {
        lastSampleAt = now
    }

    /// Records how long a sample took. Returns false once the machine has
    /// failed the budget `slowSampleLimit` times running, after which the
    /// caller must stop asking for the rest of the session.
    @discardableResult
    public mutating func record(elapsed: CFAbsoluteTime) -> Bool {
        guard elapsed > Self.budget else {
            consecutiveSlowSamples = 0
            return true
        }
        consecutiveSlowSamples += 1
        if consecutiveSlowSamples >= Self.slowSampleLimit {
            gaveUp = true
            return false
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
