import Foundation
import Metal
import MetalPerformanceShaders
import CoreGraphics
import QuartzCore

/// Reads the ambient thumbnail off the Metal drawable mpv just presented,
/// on the GPU, instead of asking mpv for a whole frame.
///
/// `screenshot-raw` pulls a full 1080p frame through mpv's core lock and a
/// CPU conversion: 5 ms on a quiet core, 55 to 60 ms under load, which made
/// the gate back off to a sample every 0.4 s and the light lag the picture
/// by half a second. The presented drawable is the finished picture, Anime4K
/// and all, already on the GPU; scaling it to 64x36 with a bilinear kernel
/// costs well under a millisecond and never touches mpv. The drawable's
/// `addPresentedHandler` is the moment its texture is complete and not yet
/// handed back to the pool, so the copy is race-free without a fence.
@MainActor
final class AmbientMetalSampler {
    /// Delivered on the main actor with the finished thumbnail and the bars
    /// found burned into it, the latter as fractions of mpv's video rect so
    /// the view can place the bands without knowing anything about drawable
    /// pixels.
    var onThumbnail: ((CGImage, AmbientContentInset) -> Void)?
    /// The playing video's display aspect, read at sample time. The
    /// drawable is the whole window, letterbox bars included; scaling all
    /// of it gave a thumbnail whose top and bottom fifths were the black
    /// bars themselves, and the glow lit the bars with their own black.
    /// The scale kernel is pointed at the aspect-fit rect inside instead.
    var videoAspect: (() -> Double?)?
    /// Minimum spacing between samples. 33 ms: every other frame at 60,
    /// every frame at 24, and about a fifth of the presents on a 120 Hz
    /// panel; the fade in the view is 80 ms, so anything tighter is unseen.
    var interval: CFTimeInterval = 0.033
    /// Spacing while nothing is lit — no window letterbox and no bars found
    /// burned into the last sample. This used to be an outright `return`,
    /// which is why baked-in bars were never noticed at all: a 16:9 file on
    /// a 16:9 screen is exactly the case a 2.35:1 scene inside a 16:9 file
    /// presents, and the sample that would have shown the bars was the one
    /// being skipped. Half a second is two scale-and-read-backs a second of
    /// a 64x36 texture, which does not register next to decoding, and it
    /// bounds how long a scene can be letterboxed before the glow catches
    /// up.
    var idleInterval: CFTimeInterval = 0.5

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scale: MPSImageBilinearScale
    private var target: MTLTexture?
    /// A second, much taller scale of the same video rect, used only to
    /// place the encoded bars' edges.
    ///
    /// The colour thumbnail is 64x36, so one of its rows is 47 px of a
    /// 1701 px picture, and `MPSImageBilinearScale` samples rather than
    /// averages under that much minification — a row is bar or picture,
    /// never a blend, so the edge could only ever be placed to the nearest
    /// row. Measured on the Grisaia cold open: the band stopped 16 px short
    /// and left exactly the black strip between the glow and the frame this
    /// probe exists to remove. At 256 rows one row is 6.6 px. Width stays
    /// at 64 because a bar spans the full width either way, so the
    /// horizontal (pillarbox) resolution is unchanged.
    private var probe: MTLTexture?
    static let probeHeight = 256
    private var lastSampleAt: CFTimeInterval = 0
    private var inFlight = false
    private var failures = 0
    private var delivered = 0
    private var smoothed: [UInt8] = []
    /// The bars found in the last sample that could tell, held across the
    /// ones that could not: a fade to black reads as bar on every side, and
    /// recomputing from it collapsed the rect and snapped it open again on
    /// the next shot.
    private var contentInset: AmbientContentInset = .zero
    /// 0.45 of the new sample per step. Heavier smoothing lived here while
    /// the view hard-cut between images; now that `AmbientGlowView` eases
    /// every colour stop over 100 ms on the render server, this only has
    /// to take the grain out, and a cut settles in three samples.
    static let smoothing: Float = 0.45
    private let debugLogging = ProcessInfo.processInfo.environment["ANICAT_PLAYER_DEBUG"] != nil

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        scale = MPSImageBilinearScale(device: device)
    }

    /// Called from the layer's `nextDrawable` override with the drawable it
    /// is about to hand to MoltenVK; the presented handler fires later.
    nonisolated func track(_ drawable: CAMetalDrawable) {
        // The presented handler does not exist in the iOS Simulator's
        // Metal; there the glow keeps the screenshot path.
        #if os(macOS) || !targetEnvironment(simulator)
        drawable.addPresentedHandler { [weak self] (presented: MTLDrawable) in
            guard let self, let metal = presented as? CAMetalDrawable else { return }
            // The texture is a GPU resource, safe to hand across threads;
            // the box is what tells the compiler so.
            let texture = SendableTexture(metal.texture)
            Task { @MainActor in self.sample(texture.texture) }
        }
        #endif
    }

    private func sample(_ source: MTLTexture) {
        let now = CACurrentMediaTime()
        guard !inFlight, failures < 5 else { return }
        let full = CGSize(width: source.width, height: source.height)
        let video = Self.aspectFit(full, aspect: videoAspect?() ?? nil)
        // Nothing to light: a 16:9 picture on a 16:9 screen (or the 320x180
        // mini-player) fills the drawable, and the last sample found no bars
        // burned into the frame either, so every band is hidden and the
        // scale, the readback and the colour stops would run thirty times a
        // second for a glow nobody could see. Slowed rather than stopped —
        // see `idleInterval` for why stopping hid the baked-in case.
        let lit = video.width < full.width - 1 || video.height < full.height - 1 || !contentInset.isZero
        guard now - lastSampleAt >= (lit ? interval : idleInterval) else { return }
        guard let size = AmbientGlow.thumbnailSize(width: Int(video.width), height: Int(video.height)) else { return }
        if target == nil || target?.width != size.width || target?.height != size.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            target = device.makeTexture(descriptor: descriptor)
        }
        if probe == nil || probe?.width != size.width || probe?.height != Self.probeHeight {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: size.width, height: Self.probeHeight, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            probe = device.makeTexture(descriptor: descriptor)
        }
        guard let target, let probe, let buffer = queue.makeCommandBuffer() else { return }
        lastSampleAt = now
        inFlight = true
        func encode(into destination: MTLTexture) {
            var transform = MPSScaleTransform(
                scaleX: Double(destination.width) / Double(video.width),
                scaleY: Double(destination.height) / Double(video.height),
                translateX: -Double(video.minX) * Double(destination.width) / Double(video.width),
                translateY: -Double(video.minY) * Double(destination.height) / Double(video.height)
            )
            withUnsafePointer(to: &transform) { scale.scaleTransform = $0 }
            scale.encode(commandBuffer: buffer, sourceTexture: source, destinationTexture: destination)
            scale.scaleTransform = nil
        }
        encode(into: target)
        encode(into: probe)
        buffer.addCompletedHandler { [weak self] finished in
            let ok = finished.error == nil
            Task { @MainActor in self?.finish(ok: ok) }
        }
        buffer.commit()
    }

    /// The bars as the tall probe sees them. Its own left/right are
    /// meaningless — the probe is only 64 wide — and are discarded by the
    /// caller.
    private func probeContentInset() -> AmbientContentInset? {
        guard let probe else { return nil }
        let width = probe.width, height = probe.height, stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        bytes.withUnsafeMutableBytes { raw in
            probe.getBytes(raw.baseAddress!, bytesPerRow: stride, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return AmbientGlow.contentInset(bytes: bytes, width: width, height: height, stride: stride)
    }

    /// Where mpv puts the picture inside the drawable: aspect-fit, centred,
    /// the same placement `PlayerView.aspectFitRect` assumes for the chrome.
    static func aspectFit(_ container: CGSize, aspect: Double?) -> CGRect {
        guard let aspect, aspect > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let containerAspect = container.width / container.height
        let size = aspect > containerAspect
            ? CGSize(width: container.width, height: (container.width / aspect).rounded())
            : CGSize(width: (container.height * aspect).rounded(), height: container.height)
        return CGRect(x: ((container.width - size.width) / 2).rounded(), y: ((container.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    private func finish(ok: Bool) {
        inFlight = false
        guard ok, let target else {
            failures += 1
            PlayerLog.write("[ambient-metal] scale failed (\(failures))")
            return
        }
        failures = 0
        delivered += 1
        if debugLogging, delivered % 60 == 1 {
            NSLog("[ambient-metal] thumbnail %d (%dx%d), %.0f ms since the previous sample", delivered, target.width, target.height, (CACurrentMediaTime() - lastSampleAt) * 1000)
        }
        let width = target.width, height = target.height, stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: stride, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // Exponential smoothing across samples, on the 64x36 pixels rather
        // than in the view: thirty raw samples a second differ by dither
        // and grain from one frame to the next, and drawn as they came the
        // bars shimmered ("flickers really fast").
        if smoothed.count == bytes.count {
            let keep = 1 - Self.smoothing, take = Self.smoothing
            for i in 0..<bytes.count {
                smoothed[i] = UInt8(Float(smoothed[i]) * keep + Float(bytes[i]) * take + 0.5)
            }
        } else {
            smoothed = bytes
        }
        bytes = smoothed
        // Top and bottom come off the tall probe, left and right off the
        // thumbnail: see `probe` for why the thumbnail cannot place a
        // horizontal edge closer than half of one of its rows. Detected on
        // the smoothed thumbnail pixels, so the inset it does contribute
        // and the picture handed over describe the same frame.
        let sides = AmbientGlow.contentInset(bytes: bytes, width: width, height: height, stride: stride)
        if let rows = probeContentInset(), let sides {
            contentInset = AmbientContentInset(
                top: rows.top, bottom: rows.bottom, left: sides.left, right: sides.right
            )
        }
        // BGRA8 in memory is an ARGB word read little-endian, the same
        // layout mpv's bgr0 screenshots use.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let full = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return }
        // The bars are cropped off before `AmbientFrame` takes its bands.
        // It reads the outer fifth of each edge, so on the Grisaia cold open
        // — 130 black rows of 1080 — the top band was two thirds black and
        // the light it cast was the bar's own colour.
        let crop = contentInset.apply(to: CGRect(x: 0, y: 0, width: width, height: height))
        let image = crop.width >= 1 && crop.height >= 1 ? (full.cropping(to: crop) ?? full) : full
        onThumbnail?(image, contentInset)
    }
}

/// `MTLTexture` is an Objective-C protocol object with no Sendable
/// annotation; Metal resources are thread-safe to reference and the
/// sampler only reads this one after the GPU has finished with it.
private struct SendableTexture: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
}
