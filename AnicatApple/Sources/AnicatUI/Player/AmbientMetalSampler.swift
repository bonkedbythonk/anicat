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
    /// Delivered on the main actor with the finished thumbnail.
    var onThumbnail: ((CGImage) -> Void)?
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

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scale: MPSImageBilinearScale
    private var target: MTLTexture?
    private var lastSampleAt: CFTimeInterval = 0
    private var inFlight = false
    private var failures = 0
    private var delivered = 0
    private var smoothed: [UInt8] = []
    static let smoothing: Float = 0.35
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
        guard !inFlight, now - lastSampleAt >= interval, failures < 5 else { return }
        let full = CGSize(width: source.width, height: source.height)
        let video = Self.aspectFit(full, aspect: videoAspect?() ?? nil)
        guard let size = AmbientGlow.thumbnailSize(width: Int(video.width), height: Int(video.height)) else { return }
        if target == nil || target?.width != size.width || target?.height != size.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let target, let buffer = queue.makeCommandBuffer() else { return }
        lastSampleAt = now
        inFlight = true
        var transform = MPSScaleTransform(
            scaleX: Double(target.width) / Double(video.width),
            scaleY: Double(target.height) / Double(video.height),
            translateX: -Double(video.minX) * Double(target.width) / Double(video.width),
            translateY: -Double(video.minY) * Double(target.height) / Double(video.height)
        )
        withUnsafePointer(to: &transform) { scale.scaleTransform = $0 }
        scale.encode(commandBuffer: buffer, sourceTexture: source, destinationTexture: target)
        scale.scaleTransform = nil
        buffer.addCompletedHandler { [weak self] finished in
            let ok = finished.error == nil
            Task { @MainActor in self?.finish(ok: ok) }
        }
        buffer.commit()
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
        // bars shimmered ("flickers really fast"). 0.35 of the new sample
        // per step settles a cut in about four samples, 130 ms, while the
        // steady picture stops twitching.
        if smoothed.count == bytes.count {
            let keep = 1 - Self.smoothing, take = Self.smoothing
            for i in 0..<bytes.count {
                smoothed[i] = UInt8(Float(smoothed[i]) * keep + Float(bytes[i]) * take + 0.5)
            }
        } else {
            smoothed = bytes
        }
        bytes = smoothed
        // BGRA8 in memory is an ARGB word read little-endian, the same
        // layout mpv's bgr0 screenshots use.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return }
        onThumbnail?(image)
    }
}

/// `MTLTexture` is an Objective-C protocol object with no Sendable
/// annotation; Metal resources are thread-safe to reference and the
/// sampler only reads this one after the GPU has finished with it.
private struct SendableTexture: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
}
