import Testing
import Foundation
import CoreGraphics
@testable import AnicatUI

@Suite("Ambient glow sampling")
struct AmbientGlowTests {
    /// A packed 32-bit frame whose colour is decided per pixel, laid out the
    /// way `screenshot-raw` hands one over: a row stride wider than the
    /// pixels, so a downscale that assumed `width * 4` would read skewed.
    private func frame(
        width: Int,
        height: Int,
        padding: Int = 16,
        order: AmbientGlow.PixelOrder = .bgr0,
        color: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> (bytes: [UInt8], stride: Int) {
        let stride = width * 4 + padding
        // Byte offsets inside one pixel, for building the fixture only. The
        // downscale itself never needs them: vImage moves all four channels
        // untouched and the order is named to CoreGraphics at the end.
        let offsets = order == .bgr0 ? (red: 2, green: 1, blue: 0) : (red: 0, green: 1, blue: 2)
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let base = y * stride + x * 4
                bytes[base + offsets.red] = r
                bytes[base + offsets.green] = g
                bytes[base + offsets.blue] = b
            }
        }
        return (bytes, stride)
    }

    private func thumbnail(
        width: Int,
        height: Int,
        order: AmbientGlow.PixelOrder = .bgr0,
        color: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> CGImage? {
        var (bytes, stride) = frame(width: width, height: height, order: order, color: color)
        return bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return AmbientGlow.thumbnail(
                bytes: base, width: width, height: height, stride: stride, order: order
            )
        }
    }

    /// Every pixel the glow layer carries is one SwiftUI blurs and scales to
    /// the whole window, so the only thing that has to hold is that a 1080p
    /// frame does not arrive as 1080p.
    @Test("A frame is downscaled to at most 64 on the long side, aspect kept")
    func downscaleDimensions() throws {
        let hd = try #require(AmbientGlow.thumbnailSize(width: 1920, height: 1080))
        #expect(hd.width == 64)
        #expect(hd.height == 36)

        let tall = try #require(AmbientGlow.thumbnailSize(width: 480, height: 640))
        #expect(tall.height == 64)
        #expect(tall.width == 48)

        // Already small enough: not scaled up, or a 4x4 test pattern would
        // arrive blurrier than the frame it came from.
        let tiny = try #require(AmbientGlow.thumbnailSize(width: 40, height: 30))
        #expect(tiny.width == 40)
        #expect(tiny.height == 30)

        #expect(AmbientGlow.thumbnailSize(width: 0, height: 1080) == nil)
    }

    @Test("The downscale produces an image of exactly those dimensions")
    func downscaleProducesImage() throws {
        let image = try #require(thumbnail(width: 320, height: 180) { _, _ in (255, 128, 0) })
        #expect(image.width == 64)
        #expect(image.height == 36)
        // Never a premultiplied variant: mpv's fourth byte is a literal 0,
        // so a premultiplied image draws the whole glow fully transparent
        // with nothing raised anywhere to say so.
        let alpha = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        #expect(alpha == .noneSkipFirst)
    }

    /// mpv reports the byte order rather than guaranteeing it, and reading it
    /// the wrong way round tints the entire app.
    @Test("The pixel order is honoured")
    func pixelOrder() throws {
        let image = try #require(thumbnail(width: 128, height: 128, order: .rgb0) { _, _ in (255, 0, 0) })
        let alpha = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        #expect(alpha == .noneSkipLast)
        #expect(AmbientGlow.PixelOrder.named("bgr0") == .bgr0)
        #expect(AmbientGlow.PixelOrder.named("rgba") == .rgb0)
        #expect(AmbientGlow.PixelOrder.named("yuv420p") == nil)
    }

    /// The gradient layers only interpolate between colour arrays of one
    /// length, so the stop count must not follow the thumbnail's size; and
    /// each bar must be lit by its own edge of the picture, red above, blue
    /// below, or the light does not line up with the frame.
    @Test("Colour stops have fixed counts and come from their own edge")
    func colourStops() throws {
        let image = try #require(thumbnail(width: 320, height: 180) { _, y in
            y < 90 ? (255, 0, 0) : (0, 0, 255)
        })
        let frame = AmbientFrame(id: 1, image: image)
        #expect(frame.topColors.count == AmbientFrame.horizontalStops)
        #expect(frame.bottomColors.count == AmbientFrame.horizontalStops)
        #expect(frame.leftColors.count == AmbientFrame.verticalStops)
        #expect(frame.rightColors.count == AmbientFrame.verticalStops)
        let top = try #require(frame.topColors[16].components)
        #expect(top[0] > 0.6 && top[2] < 0.2)
        let bottom = try #require(frame.bottomColors[16].components)
        #expect(bottom[2] > 0.6 && bottom[0] < 0.2)
        // The pillars run top to bottom: first stop red, last stop blue.
        let first = try #require(frame.leftColors.first?.components)
        let last = try #require(frame.leftColors.last?.components)
        #expect(first[0] > 0.6 && last[2] > 0.6)
    }

    @Test("A malformed frame yields nothing rather than reading past it")
    func rejectsMalformed() {
        var bytes = [UInt8](repeating: 0, count: 64)
        let image: CGImage? = bytes.withUnsafeMutableBytes { raw in
            AmbientGlow.thumbnail(
                bytes: raw.baseAddress!, width: 16, height: 4, stride: 8, order: .bgr0
            )
        }
        #expect(image == nil)
    }

    /// The gate is what keeps `screenshot-raw` from costing playback: it runs
    /// on mpv's core lock, so a sample that goes long is a dropped frame.
    @Test("The gate holds samples to the interval")
    func gateInterval() {
        var gate = AmbientSampleGate()
        #expect(gate.isDue(at: 100))
        gate.begin(at: 100)
        #expect(!gate.isDue(at: 100 + AmbientSampleGate.interval / 2))
        #expect(gate.isDue(at: 100 + AmbientSampleGate.interval))
    }

    /// Slow samples back the interval off instead of stopping sampling: a
    /// stopped sampler froze the bars on the episode still for the whole
    /// session, which read as the glow being stuck.
    @Test("Three slow samples in a row double the interval, twenty fast ones halve it back")
    func gateBacksOffAndRecovers() {
        var gate = AmbientSampleGate()
        for _ in 0..<3 { gate.record(elapsed: 0.050) }
        #expect(gate.currentInterval == AmbientSampleGate.interval * 2)
        #expect(!gate.gaveUp)
        for _ in 0..<30 { gate.record(elapsed: 0.050) }
        #expect(gate.currentInterval == AmbientSampleGate.maxInterval)
        for _ in 0..<AmbientSampleGate.recoverySampleLimit { gate.record(elapsed: 0.002) }
        #expect(gate.currentInterval == AmbientSampleGate.maxInterval / 2)
        // Scattered slow samples never move it.
        var scattered = AmbientSampleGate()
        for _ in 0..<10 {
            scattered.record(elapsed: 0.050)
            scattered.record(elapsed: 0.002)
        }
        #expect(scattered.currentInterval == AmbientSampleGate.interval)
    }

    @Test("An unsupported screenshot stops the sampler outright")
    func gateGivesUpWhenUnsupported() {
        var gate = AmbientSampleGate()
        gate.giveUp()
        #expect(gate.gaveUp)
        #expect(!gate.isDue(at: 10_000))
    }

    /// The Grisaia case, at thumbnail scale: a 16:9 file whose picture is
    /// 2.35:1 with the bars burned in. `contentInset` is the only thing that
    /// can see them — every property mpv reports says 1920x1080, 16:9,
    /// sample aspect 1:1.
    @Test("Bars encoded into the frame are found as fractions of it")
    func encodedBarsAreDetected() throws {
        let barRows = 4, height = 36, width = 64
        let (bytes, stride) = frame(width: width, height: height) { _, y in
            (y < barRows || y >= height - barRows) ? (0, 0, 0) : (200, 180, 160)
        }
        let inset = try #require(AmbientGlow.contentInset(bytes: bytes, width: width, height: height, stride: stride))
        #expect(inset.top == Double(barRows) / Double(height))
        #expect(inset.bottom == Double(barRows) / Double(height))
        #expect(inset.left == 0)
        #expect(inset.right == 0)
    }

    @Test("A picture that fills its frame reports no bars at all")
    func fullFrameHasNoInset() throws {
        let (bytes, stride) = frame(width: 64, height: 36) { _, _ in (120, 120, 120) }
        let inset = try #require(AmbientGlow.contentInset(bytes: bytes, width: 64, height: 36, stride: stride))
        #expect(inset.isZero)
    }

    /// Without this the rect collapsed on every fade and snapped back open
    /// on the next shot.
    @Test("A frame too dark to tell reports nothing rather than a full inset")
    func fadeToBlackReportsNothing() {
        let (bytes, stride) = frame(width: 64, height: 36) { _, _ in (0, 0, 0) }
        #expect(AmbientGlow.contentInset(bytes: bytes, width: 64, height: 36, stride: stride) == nil)
    }

    /// A dark scene is not a bar: the threshold has to sit under the darkest
    /// picture rather than over the brightest black.
    @Test("Rows just above the bar level are picture, not bar")
    func darkPictureIsNotABar() throws {
        let level = AmbientGlow.barLevel + 4
        let (bytes, stride) = frame(width: 64, height: 36) { _, y in
            y < 4 ? (level, level, level) : (200, 200, 200)
        }
        let inset = try #require(AmbientGlow.contentInset(bytes: bytes, width: 64, height: 36, stride: stride))
        #expect(inset.top == 0)
    }

    @Test("Pillarbox bars encoded into the frame are found too")
    func encodedPillarboxIsDetected() throws {
        let barColumns = 8, width = 64, height = 36
        let (bytes, stride) = frame(width: width, height: height) { x, _ in
            (x < barColumns || x >= width - barColumns) ? (0, 0, 0) : (90, 140, 210)
        }
        let inset = try #require(AmbientGlow.contentInset(bytes: bytes, width: width, height: height, stride: stride))
        #expect(inset.left == Double(barColumns) / Double(width))
        #expect(inset.right == Double(barColumns) / Double(width))
        #expect(inset.top == 0)
    }

    /// The bands are placed from this, against the video rect the chrome
    /// already computes, so the arithmetic has to stay in that space.
    @Test("An inset maps onto the video rect the chrome laid out")
    func insetAppliesToTheVideoRect() {
        let inset = AmbientContentInset(top: 0.1, bottom: 0.2, left: 0, right: 0)
        let rect = inset.apply(to: CGRect(x: 0, y: 50, width: 1000, height: 500))
        #expect(rect.minX == 0)
        #expect(rect.width == 1000)
        #expect(rect.minY == 100)
        #expect(rect.height == 350)
    }

    /// The centring in `bandEdges` is mpv's, and it is right for the
    /// window's own letterbox — but it takes only the picture's *size*, so
    /// an encoded bar on one edge alone used to be split across both and
    /// half the glow drawn over the picture.
    @Test("A one-sided encoded bar stays on its own edge")
    func oneSidedInsetIsNotRecentred() {
        let window = CGSize(width: 1000, height: 500)
        let video = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let edges = AmbientGlowView.bandEdges(
            video: video,
            contentInset: AmbientContentInset(top: 0.2, bottom: 0, left: 0, right: 0),
            windowSize: window,
            scale: 2
        )
        #expect(edges.top == 100)
        #expect(edges.bottom == 500)
    }

    @Test("With no encoded bars the band edges are the window letterbox alone")
    func zeroInsetKeepsTheLetterboxEdges() {
        let window = CGSize(width: 1000, height: 600)
        let video = CGRect(x: 0, y: 50, width: 1000, height: 500)
        let edges = AmbientGlowView.bandEdges(
            video: video, contentInset: .zero, windowSize: window, scale: 2
        )
        #expect(edges.top == 50)
        #expect(edges.bottom == 550)
        #expect(edges.left == 0)
        #expect(edges.right == 1000)
    }

    /// The thumbnail is a bilinear downscale, so the row the picture's edge
    /// falls in is part bar and part picture and never passes the bar test.
    /// Counting whole rows alone left 16 px of black between the glow and
    /// the frame on the Grisaia cold open.
    @Test("The row the picture edge falls in is credited by how much of it was bar")
    func blendedBoundaryRowIsCredited() throws {
        let width = 64, height = 36
        // Rows 0-3 bar, row 4 three-quarters bar, the rest picture.
        let picture: UInt8 = 200
        let blended = UInt8(Double(picture) * 0.25)
        let (bytes, stride) = frame(width: width, height: height) { _, y in
            if y < 4 { return (0, 0, 0) }
            if y == 4 { return (blended, blended, blended) }
            return (picture, picture, picture)
        }
        let inset = try #require(AmbientGlow.contentInset(bytes: bytes, width: width, height: height, stride: stride))
        let credited = inset.top * Double(height)
        #expect(credited > 4.6 && credited < 4.9)
    }

    /// A hard edge has nothing to credit, and crediting one anyway would put
    /// the band a row over the picture.
    @Test("A hard picture edge is not extended into")
    func hardEdgeIsNotExtended() throws {
        let (bytes, stride) = frame(width: 64, height: 36) { _, y in
            y < 4 ? (0, 0, 0) : (200, 200, 200)
        }
        let inset = try #require(AmbientGlow.contentInset(bytes: bytes, width: 64, height: 36, stride: stride))
        #expect(inset.top == 4.0 / 36.0)
    }

    /// Refining off a picture barely brighter than a bar is guesswork, and
    /// guessing long draws glow over the frame.
    @Test("A picture too close to black to tell is left as whole rows")
    func lowContrastEdgeIsNotRefined() throws {
        let (bytes, stride) = frame(width: 64, height: 36) { _, y in
            y < 4 ? (0, 0, 0) : (30, 30, 30)
        }
        let inset = try #require(AmbientGlow.contentInset(bytes: bytes, width: 64, height: 36, stride: stride))
        #expect(inset.top == 4.0 / 36.0)
    }
}
