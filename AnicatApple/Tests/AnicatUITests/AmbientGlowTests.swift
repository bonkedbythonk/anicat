import Testing
import Foundation
@testable import AnicatUI

@Suite("Ambient glow sampling")
struct AmbientGlowTests {
    /// A packed 32-bit frame whose colour is decided per pixel, laid out the
    /// way `screenshot-raw` hands one over: a row stride wider than the
    /// pixels, so a sampler that assumed `width * 4` would read skewed.
    private func frame(
        width: Int,
        height: Int,
        padding: Int = 16,
        order: AmbientGlow.PixelOrder = .bgr0,
        color: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> (bytes: [UInt8], stride: Int) {
        let stride = width * 4 + padding
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let base = y * stride + x * 4
                bytes[base + order.red] = r
                bytes[base + order.green] = g
                bytes[base + order.blue] = b
            }
        }
        return (bytes, stride)
    }

    @Test("A flat frame samples to its own colour on every edge")
    func flatFrame() throws {
        let (bytes, stride) = frame(width: 64, height: 64) { _, _ in (255, 128, 0) }
        let edges: AmbientEdges? = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let grid = AmbientGlow.grid(bytes: base, width: 64, height: 64, stride: stride, order: .bgr0)
            else { return nil }
            return AmbientGlow.edges(fromGrid: grid)
        }
        let result = try #require(edges)
        let top = result.top
        #expect(abs(top.red - 1) < 0.01)
        #expect(abs(top.green - 128.0 / 255) < 0.01)
        #expect(abs(top.blue) < 0.01)
        #expect(result.left == top)
    }

    /// The point of the four strips: a frame that is red at the top and blue
    /// at the bottom has to light the two bars differently, or the whole
    /// feature is one average colour with extra steps.
    @Test("Top and bottom strips see different halves of the frame")
    func verticalSplit() throws {
        let (bytes, stride) = frame(width: 64, height: 64) { _, y in
            y < 32 ? (255, 0, 0) : (0, 0, 255)
        }
        let edges: AmbientEdges? = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let grid = AmbientGlow.grid(bytes: base, width: 64, height: 64, stride: stride, order: .bgr0)
            else { return nil }
            return AmbientGlow.edges(fromGrid: grid)
        }
        let result = try #require(edges)
        #expect(result.top.red > 0.9)
        #expect(result.top.blue < 0.1)
        #expect(result.bottom.blue > 0.9)
        #expect(result.bottom.red < 0.1)
        // The side strips run the full height, so both see both halves.
        #expect(abs(result.left.red - 0.5) < 0.1)
        #expect(abs(result.left.blue - 0.5) < 0.1)
    }

    /// mpv reports the byte order rather than guaranteeing it, and reading it
    /// the wrong way round tints the entire app.
    @Test("The pixel order is honoured")
    func pixelOrder() throws {
        let (bytes, stride) = frame(width: 32, height: 32, order: .rgb0) { _, _ in (255, 0, 0) }
        let edges: AmbientEdges? = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let grid = AmbientGlow.grid(bytes: base, width: 32, height: 32, stride: stride, order: .rgb0)
            else { return nil }
            return AmbientGlow.edges(fromGrid: grid)
        }
        let result = try #require(edges)
        #expect(result.top.red > 0.9)
        #expect(AmbientGlow.PixelOrder.named("bgr0") == .bgr0)
        #expect(AmbientGlow.PixelOrder.named("rgba") == .rgb0)
        #expect(AmbientGlow.PixelOrder.named("yuv420p") == nil)
    }

    @Test("A malformed frame yields nothing rather than reading past it")
    func rejectsMalformed() {
        let bytes = [UInt8](repeating: 0, count: 64)
        let grid: [AmbientRGB]? = bytes.withUnsafeBytes { raw in
            AmbientGlow.grid(bytes: raw.baseAddress!, width: 16, height: 4, stride: 8, order: .bgr0)
        }
        #expect(grid == nil)
        #expect(AmbientGlow.edges(fromGrid: []) == nil)
    }
}
