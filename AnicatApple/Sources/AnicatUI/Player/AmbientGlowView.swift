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
    /// Where mpv puts the picture, letterboxed into the window. Handed over
    /// whole rather than pre-inset: the band edges are derived from it with
    /// mpv's own integer arithmetic (see `AmbientGlowHostView.apply`), and a
    /// rect that had already had the encoded bars taken off would be run
    /// through that centring and come back mispositioned.
    let video: CGRect
    /// Black bars encoded into the frame itself, applied to `video` in
    /// pixels after the centring.
    let contentInset: AmbientContentInset
    let windowSize: CGSize
    let reduceMotion: Bool

    /// How long each stop takes to reach a new sample's colour. Longer than
    /// the 33 ms sample spacing so consecutive samples overlap into one
    /// continuous drift; 100 ms is the lag the eye reads as "with the
    /// picture" while a scene cut still lands well inside a beat.
    static let easeDuration: CFTimeInterval = 0.10
    /// The layer's opacity; the same 0.6 the blurred version used.
    static let opacity: Float = 0.6

    /// Where each band stops, in points from the window's top-left: the
    /// picture's own edges once mpv has letterboxed it and once the bars
    /// encoded into the frame have been taken off.
    ///
    /// Pure so the two cases that broke can be checked without a running
    /// player — an asymmetric encoded inset, and the fractional-rect seam.
    ///
    /// Band edges land on the device pixels mpv puts the picture on.
    /// SwiftUI's rect is fractional (top 58.875 pt on a 732 pt window,
    /// 117.75 px) while mpv truncates the picture height to whole pixels
    /// and centres it with integer division: 1228 px tall, top margin
    /// (1464 - 1228) / 2 = 118. A band cut at the fractional rect left a
    /// row neither drew, a black hairline under the picture (8.6 against
    /// 38 either side in a capture); one overlapping by a point was a
    /// bright hairline instead; flooring both edges put the black row
    /// above the picture. So the same arithmetic as mpv, in pixels.
    nonisolated static func bandEdges(
        video: CGRect,
        contentInset: AmbientContentInset,
        windowSize: CGSize,
        scale: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        let layerWidth = (windowSize.width * scale).rounded(), layerHeight = (windowSize.height * scale).rounded()
        let pictureWidth = min(layerWidth, (video.width * scale).rounded(.down))
        let pictureHeight = min(layerHeight, (video.height * scale).rounded(.down))
        let leftPixel = ((layerWidth - pictureWidth) / 2).rounded(.down)
        let topPixel = ((layerHeight - pictureHeight) / 2).rounded(.down)
        // The encoded bars come off here, and never through the centring
        // above: they are not symmetric (the Grisaia cold open is 130 rows
        // over the picture and 131 under it), and a detector that finds a
        // bar on one edge only — a scene whose other edge happens to be
        // bright — would have had its one bar split in half by the centring
        // and half the glow drawn over the picture.
        let barTop = (pictureHeight * contentInset.top).rounded()
        let barBottom = (pictureHeight * contentInset.bottom).rounded()
        let barLeft = (pictureWidth * contentInset.left).rounded()
        let barRight = (pictureWidth * contentInset.right).rounded()
        let contentTop = topPixel + barTop
        let contentHeight = max(0, pictureHeight - barTop - barBottom)
        let contentLeft = leftPixel + barLeft
        let contentWidth = max(0, pictureWidth - barLeft - barRight)
        return (
            top: contentTop / scale,
            bottom: (contentTop + contentHeight) / scale,
            left: contentLeft / scale,
            right: (contentLeft + contentWidth) / scale
        )
    }

    @MainActor
    func apply(to host: AmbientGlowHostView) {
        host.apply(frame: frame, video: video, contentInset: contentInset, windowSize: windowSize, animated: !reduceMotion)
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

    func apply(
        frame: AmbientFrame,
        video: CGRect,
        contentInset: AmbientContentInset,
        windowSize: CGSize,
        animated: Bool
    ) {
        // Geometry never animates: a band that eased into a new window size
        // would spend 100 ms over the picture or short of the edge.
        let scale = pixelScale
        let edges = AmbientGlowView.bandEdges(video: video, contentInset: contentInset, windowSize: windowSize, scale: scale)
        let topEdge = edges.top, bottomEdge = edges.bottom
        let leftEdge = edges.left, rightEdge = edges.right
        // One device pixel of overlap into the picture, and exactly one.
        //
        // Matching mpv's arithmetic puts the band edge on the same pixel the
        // picture starts on, and a seam still showed there: the two surfaces
        // are composited separately, so the boundary row blends against the
        // black behind rather than against the picture. Overlapping by a
        // *point* was the earlier attempt and read as a bright line -- at 2x
        // that is two pixels of glow over the picture. One pixel is covered
        // by the band whose colour was sampled from that very row, so there
        // is nothing to see either way.
        let bleed = 1 / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.frame = CGRect(x: 0, y: 0, width: windowSize.width, height: max(0, topEdge + bleed))
        bottom.frame = CGRect(
            x: 0,
            y: bottomEdge - bleed,
            width: windowSize.width,
            height: max(0, windowSize.height - bottomEdge + bleed)
        )
        left.frame = CGRect(x: 0, y: topEdge, width: max(0, leftEdge + bleed), height: bottomEdge - topEdge)
        right.frame = CGRect(
            x: rightEdge - bleed,
            y: topEdge,
            width: max(0, windowSize.width - rightEdge + bleed),
            height: bottomEdge - topEdge
        )
        // Against the computed edges, not the passed rect: with the bars
        // encoded into the frame there is nothing in `video` to hide on.
        top.isHidden = topEdge < 0.5
        bottom.isHidden = windowSize.height - bottomEdge < 0.5
        left.isHidden = leftEdge < 0.5
        right.isHidden = windowSize.width - rightEdge < 0.5
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
