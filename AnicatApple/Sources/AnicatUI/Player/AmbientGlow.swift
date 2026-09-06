import Foundation
import SwiftUI
import CoreGraphics
import ImageIO

/// A linear-light-ish colour in 0...1, kept as a plain value so the sampling
/// below can be exercised without a running player and without SwiftUI.
public struct AmbientRGB: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = AmbientRGB(red: 0, green: 0, blue: 0)

    public var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    static func mean(_ values: [AmbientRGB]) -> AmbientRGB {
        guard !values.isEmpty else { return .black }
        let count = Double(values.count)
        return AmbientRGB(
            red: values.reduce(0) { $0 + $1.red } / count,
            green: values.reduce(0) { $0 + $1.green } / count,
            blue: values.reduce(0) { $0 + $1.blue } / count
        )
    }
}

/// What each side of the picture is bleeding into the black around it.
public struct AmbientEdges: Sendable, Equatable {
    public var top: AmbientRGB
    public var bottom: AmbientRGB
    public var left: AmbientRGB
    public var right: AmbientRGB

    public init(top: AmbientRGB, bottom: AmbientRGB, left: AmbientRGB, right: AmbientRGB) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public init(uniform: AmbientRGB) {
        self.init(top: uniform, bottom: uniform, left: uniform, right: uniform)
    }

    public static let neutral = AmbientEdges(uniform: .black)

    /// What the mini-player's halo is tinted with — one colour for a frame
    /// small enough that four would read as noise.
    public var mean: AmbientRGB {
        AmbientRGB.mean([top, bottom, left, right])
    }
}

public enum AmbientGlow {
    /// Byte offsets of red, green and blue inside one 4-byte pixel. mpv's
    /// `screenshot-raw` answers `bgr0` on every build this app ships with,
    /// but the command documents the format as a field rather than a
    /// guarantee, and reading it the wrong way round tints the whole app.
    public struct PixelOrder: Sendable, Equatable {
        public let red: Int
        public let green: Int
        public let blue: Int

        public static let bgr0 = PixelOrder(red: 2, green: 1, blue: 0)
        public static let rgb0 = PixelOrder(red: 0, green: 1, blue: 2)

        public static func named(_ format: String) -> PixelOrder? {
            switch format.lowercased() {
            case "bgr0", "bgra": return .bgr0
            case "rgb0", "rgba": return .rgb0
            default: return nil
            }
        }
    }

    /// The downsampled frame is 8x8 — enough for four edge strips and no
    /// more, since everything drawn from it is a wash behind a blurred
    /// gradient.
    public static let gridSide = 8

    /// Mean of each edge strip of a row-major 8x8 grid. The corners belong to
    /// two strips each, which is what makes the four colours agree where they
    /// meet instead of banding at the corners.
    public static func edges(fromGrid grid: [AmbientRGB]) -> AmbientEdges? {
        let side = gridSide
        guard grid.count == side * side else { return nil }
        return AmbientEdges(
            top: AmbientRGB.mean(Array(grid[0..<side])),
            bottom: AmbientRGB.mean(Array(grid[(side * (side - 1))...])),
            left: AmbientRGB.mean((0..<side).map { grid[$0 * side] }),
            right: AmbientRGB.mean((0..<side).map { grid[$0 * side + side - 1] })
        )
    }

    /// Downsamples a packed 32-bit frame to 8x8 by point-sampling 64 points
    /// per cell.
    ///
    /// Not vImage, and not a full-frame reduction: a 1080p frame is 8 MB, and
    /// averaging every pixel of it — or handing it to vImage, which has to
    /// read all of it too — costs far more than the 4096 scattered reads this
    /// does, for a result that ends up behind a gradient either way. The
    /// expensive half of this feature is `screenshot-raw` itself, which
    /// allocates and copies that frame under mpv's core lock; nothing here
    /// should add to it.
    public static func grid(
        bytes: UnsafeRawPointer,
        width: Int,
        height: Int,
        stride: Int,
        order: PixelOrder
    ) -> [AmbientRGB]? {
        let side = gridSide
        let samplesPerSide = 8
        let steps = side * samplesPerSide
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        var grid: [AmbientRGB] = []
        grid.reserveCapacity(side * side)
        for cellY in 0..<side {
            for cellX in 0..<side {
                var red = 0.0, green = 0.0, blue = 0.0
                var counted = 0
                for sampleY in 0..<samplesPerSide {
                    let y = min(((cellY * samplesPerSide + sampleY) * height) / steps, height - 1)
                    let row = bytes.advanced(by: y * stride)
                    for sampleX in 0..<samplesPerSide {
                        let x = min(((cellX * samplesPerSide + sampleX) * width) / steps, width - 1)
                        let pixel = row.advanced(by: x * 4)
                        red += Double(pixel.load(fromByteOffset: order.red, as: UInt8.self))
                        green += Double(pixel.load(fromByteOffset: order.green, as: UInt8.self))
                        blue += Double(pixel.load(fromByteOffset: order.blue, as: UInt8.self))
                        counted += 1
                    }
                }
                let scale = Double(counted) * 255
                grid.append(AmbientRGB(red: red / scale, green: green / scale, blue: blue / scale))
            }
        }
        return grid
    }

    /// The fallback source: one colour for the whole episode, from its still.
    /// Always computed, whether or not frame sampling is available, so a
    /// player that never gets a usable screenshot still has something to
    /// bleed — and so the glow is up before the first frame has decoded.
    public static func averageColor(of url: URL) async -> AmbientRGB? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary)
        else { return nil }
        // A 1x1 context is the cheapest area average there is: Core Graphics
        // does the box filter on the way in.
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return AmbientRGB(
            red: Double(pixel[0]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255
        )
    }
}
