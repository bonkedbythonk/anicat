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
}
