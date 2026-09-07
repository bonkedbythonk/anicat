import SwiftUI
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The letterbox light, drawn as four `CAGradientLayer`s whose `colors`
/// Core Animation interpolates on the render server.
///
/// The previous version blurred a 64x1 strip of picture into each bar and
/// cross-faded SwiftUI images at the sample rate. A new image every 33 to
/// 50 ms, each an 80 ms fade over the last, is a stepped signal however
/// the two layers are stacked: the picture under the fade hard-cut at
/// whatever alpha the ramp had reached, at the irregular cadence the
/// drawable's presents arrive at, and the bars shimmered ("still
/// flickers"). A gradient layer's colour stops are animatable state: each
/// sample sets the target and Core Animation eases every stop from where
/// it is now, per display frame, with no rasterization and nothing that
/// can hard-cut. The falloff across the bar is a mask gradient, so the blur
/// is gone too; a 32-stop gradient over a 1920 pt bar is already smoother
/// than a 36 pt blur of a 64 px strip.
struct AmbientGlowView {
    let frame: AmbientFrame
    let video: CGRect
    let windowSize: CGSize
    let reduceMotion: Bool

    /// How long each stop takes to reach a new sample's colour. Longer than
    /// the 33 ms sample spacing so consecutive samples overlap into one
    /// continuous drift; 100 ms is the lag the eye reads as "with the
    /// picture" while a scene cut still lands well inside a beat.
    static let easeDuration: CFTimeInterval = 0.10
    /// The layer's opacity; the same 0.6 the blurred version used.
    static let opacity: Float = 0.6

    @MainActor
    func apply(to host: AmbientGlowHostView) {
        host.apply(frame: frame, video: video, windowSize: windowSize, animated: !reduceMotion)
    }
}

#if os(macOS)
extension AmbientGlowView: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientGlowHostView {
        let view = AmbientGlowHostView()
        apply(to: view)
        return view
    }
    func updateNSView(_ nsView: AmbientGlowHostView, context: Context) {
        apply(to: nsView)
    }
}
typealias AmbientGlowPlatformView = NSView
#else
extension AmbientGlowView: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientGlowHostView {
        let view = AmbientGlowHostView()
        apply(to: view)
        return view
    }
    func updateUIView(_ uiView: AmbientGlowHostView, context: Context) {
        apply(to: uiView)
    }
}
typealias AmbientGlowPlatformView = UIView
#endif

final class AmbientGlowHostView: AmbientGlowPlatformView {
    private let top = AmbientGlowBandLayer(axis: .horizontal, brightEdge: .bottom)
    private let bottom = AmbientGlowBandLayer(axis: .horizontal, brightEdge: .top)
    private let left = AmbientGlowBandLayer(axis: .vertical, brightEdge: .right)
    private let right = AmbientGlowBandLayer(axis: .vertical, brightEdge: .left)
    private var lastFrameID: Int?

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        #if os(macOS)
        wantsLayer = true
        #endif
        for band in [top, bottom, left, right] {
            hostLayer.addSublayer(band)
        }
    }

    required init?(coder: NSCoder) { nil }

    #if os(macOS)
    /// Top-left origin, so a band's rect can be the SwiftUI rect it is
    /// handed. Flipping the view flips its layer tree with it, gradient
    /// start points included.
    override var isFlipped: Bool { true }
    private var hostLayer: CALayer { layer! }
    private var pixelScale: CGFloat { window?.backingScaleFactor ?? 2 }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #else
    private var hostLayer: CALayer { layer }
    private var pixelScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    #endif

    func apply(frame: AmbientFrame, video: CGRect, windowSize: CGSize, animated: Bool) {
        // Geometry never animates: a band that eased into a new window size
        // would spend 100 ms over the picture or short of the edge.
        // Band edges land on the device pixels mpv puts the picture on.
        // SwiftUI's rect is fractional (top 58.875 pt on a 732 pt window,
        // 117.75 px) while mpv truncates the picture height to whole pixels
        // and centres it with integer division: 1228 px tall, top margin
        // (1464 - 1228) / 2 = 118. A band cut at the fractional rect left a
        // row neither drew, a black hairline under the picture (8.6 against
        // 38 either side in a capture); one overlapping by a point was a
        // bright hairline instead; flooring both edges put the black row
        // above the picture. So the same arithmetic as mpv, in pixels.
        let scale = pixelScale
        let layerWidth = (windowSize.width * scale).rounded(), layerHeight = (windowSize.height * scale).rounded()
        let pictureWidth = min(layerWidth, (video.width * scale).rounded(.down))
        let pictureHeight = min(layerHeight, (video.height * scale).rounded(.down))
        let leftPixel = ((layerWidth - pictureWidth) / 2).rounded(.down)
        let topPixel = ((layerHeight - pictureHeight) / 2).rounded(.down)
        let topEdge = topPixel / scale, bottomEdge = (topPixel + pictureHeight) / scale
        let leftEdge = leftPixel / scale, rightEdge = (leftPixel + pictureWidth) / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.frame = CGRect(x: 0, y: 0, width: windowSize.width, height: max(0, topEdge))
        bottom.frame = CGRect(x: 0, y: bottomEdge, width: windowSize.width, height: max(0, windowSize.height - bottomEdge))
        left.frame = CGRect(x: 0, y: topEdge, width: max(0, leftEdge), height: bottomEdge - topEdge)
        right.frame = CGRect(x: rightEdge, y: topEdge, width: max(0, windowSize.width - rightEdge), height: bottomEdge - topEdge)
        top.isHidden = video.minY < 0.5
        bottom.isHidden = windowSize.height - video.maxY < 0.5
        left.isHidden = video.minX < 0.5
        right.isHidden = windowSize.width - video.maxX < 0.5
        for band in [top, bottom, left, right] {
            band.layoutMask()
        }
        CATransaction.commit()

        guard lastFrameID != frame.id else { return }
        // The first picture, and Reduce Motion, land without a ramp.
        let duration = animated && lastFrameID != nil ? AmbientGlowView.easeDuration : 0
        lastFrameID = frame.id
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        top.colors = frame.topColors
        bottom.colors = frame.bottomColors
        left.colors = frame.leftColors
        right.colors = frame.rightColors
        CATransaction.commit()
    }
}

/// One bar: a gradient of the picture's edge colours along the bar, under
/// an alpha mask that is brightest against the picture and dim at the
/// window edge, the way light off a screen falls off across a wall.
final class AmbientGlowBandLayer: CAGradientLayer {
    enum Axis { case horizontal, vertical }
    enum Edge { case top, bottom, left, right }

    private let fade = CAGradientLayer()

    init(axis: Axis, brightEdge: Edge) {
        super.init()
        switch axis {
        case .horizontal:
            startPoint = CGPoint(x: 0, y: 0.5)
            endPoint = CGPoint(x: 1, y: 0.5)
        case .vertical:
            startPoint = CGPoint(x: 0.5, y: 0)
            endPoint = CGPoint(x: 0.5, y: 1)
        }
        opacity = AmbientGlowView.opacity
        // The 0.2 floor is what keeps the far edge of a deep bar from
        // reading as unlit black next to a lit one.
        fade.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0.2)]
        switch brightEdge {
        case .top:
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
        case .bottom:
            fade.startPoint = CGPoint(x: 0.5, y: 1); fade.endPoint = CGPoint(x: 0.5, y: 0)
        case .left:
            fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        case .right:
            fade.startPoint = CGPoint(x: 1, y: 0.5); fade.endPoint = CGPoint(x: 0, y: 0.5)
        }
        mask = fade
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func layoutMask() {
        fade.frame = bounds
    }
}
