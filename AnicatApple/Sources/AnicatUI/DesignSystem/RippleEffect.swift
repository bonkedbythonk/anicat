import SwiftUI

/// One clean ring, tuned by eye against the poster grid: shorter and it
/// reads as a glitch before the eye can track the ring outward; longer and
/// it lingers past the point where the tap it is confirming has already
/// been forgotten. A file-scope constant rather than a static member on
/// `RippleEffect`: `keyframeAnimator`'s closures are `@Sendable`, and
/// reading a static property of a generic type through `Self` from inside
/// one made the compiler flag the capture of `T.Type` across the boundary —
/// a plain `let` has no such metatype to carry.
private let rippleDuration: TimeInterval = 0.8

/// The WWDC24 sample ripple: a `keyframeAnimator` runs a plain `Double` from
/// 0 to `rippleDuration` seconds and hands that elapsed time to the `ripple`
/// Metal shader every frame, which is what turns a static displacement
/// into something that travels outward and decays.
public struct RippleEffect<T: Equatable>: ViewModifier {
    var origin: CGPoint
    var trigger: T

    public init(at origin: CGPoint, trigger: T) {
        self.origin = origin
        self.trigger = trigger
    }

    public func body(content: Content) -> some View {
        // A no-op under Reduce Motion rather than a shorter ripple: the
        // shader still samples every frame it runs, and reduced motion is
        // a request for *less movement*, not a faster version of the same
        // movement.
        if MotionPolicy.reduce {
            content
        } else {
            content.keyframeAnimator(
                initialValue: 0.0,
                trigger: trigger
            ) { view, elapsedTime in
                view.modifier(
                    RippleShaderModifier(
                        origin: origin,
                        elapsedTime: elapsedTime,
                        duration: rippleDuration
                    )
                )
            } keyframes: { _ in
                MoveKeyframe(0.0)
                LinearKeyframe(rippleDuration, duration: rippleDuration)
            }
        }
    }
}

/// Wraps `.layerEffect` on its own so `RippleEffect.body` stays a plain
/// `if`/`else` — `keyframeAnimator`'s trailing closure infers its return
/// type from the single expression inside, and a second branch (an
/// `isEnabled` check computed inline) made that inference fail.
private struct RippleShaderModifier: ViewModifier {
    var origin: CGPoint
    var elapsedTime: TimeInterval
    var duration: TimeInterval

    var amplitude: Double = 12
    var frequency: Double = 15
    var decay: Double = 8
    var speed: Double = 1200

    /// One metallib per platform slice, picked here; a macOS library
    /// loaded on the simulator fails silently and the ripple draws nothing.
    /// nil when the file is missing, in which case the effect is a no-op
    /// rather than a `layerEffect` over an unresolvable function.
    private static let library: ShaderLibrary? = {
        #if os(macOS)
        let slice = "macosx"
        #elseif targetEnvironment(simulator)
        let slice = "iphonesimulator"
        #else
        let slice = "iphoneos"
        #endif
        guard let url = Bundle.anicatResources.url(
            forResource: "AnicatShaders.\(slice)",
            withExtension: "metallib",
            subdirectory: "Shaders/metal"
        ) else {
            print("[ripple] AnicatShaders.\(slice).metallib not in the bundle; ripple disabled")
            return nil
        }
        return ShaderLibrary(url: url)
    }()

    func body(content: Content) -> some View {
        // Not `ShaderLibrary.bundle(.module)`: `swift build` never compiles
        // a `.metal` source, so the module bundle has no `ripple` at all, and
        // a raw `Bundle.module` crashes a packaged Anicat.app at launch
        // (see `Bundle.anicatResources`). The library is precompiled by
        // scripts/build-shaders.sh and shipped in the Shaders folder.
        guard let library = Self.library else {
            return AnyView(content)
        }
        let shader = library.ripple(
            .float2(origin),
            .float(elapsedTime),
            .float(amplitude),
            .float(frequency),
            .float(decay),
            .float(speed)
        )

        return AnyView(content.layerEffect(
            shader,
            maxSampleOffset: CGSize(width: amplitude, height: amplitude),
            isEnabled: 0 < elapsedTime && elapsedTime < duration
        ))
    }
}

public extension View {
    /// Fires a Metal ripple centred on `origin` whenever `trigger` changes.
    /// Callers set `origin` from the press location that starts a play
    /// (falling back to the view's centre when no gesture location is
    /// available yet) and bump `trigger` on the same press. Runs on top of
    /// whatever else the view already does on that press — it is a layer
    /// effect, not a replacement transition.
    func rippleOnPress<T: Equatable>(at origin: CGPoint, trigger: T) -> some View {
        modifier(RippleEffect(at: origin, trigger: trigger))
    }
}
