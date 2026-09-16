#include <metal_stdlib>
using namespace metal;

#include <SwiftUI/SwiftUI_Metal.h>

/// The WWDC24 "Create custom visual effects with SwiftUI" ripple, unchanged
/// in shape: a radial displacement whose amplitude is a sine damped by
/// `exp(-decay * time)`, delayed per-pixel by its distance from `origin`
/// divided by `speed` so the ring actually travels outward instead of the
/// whole layer pulsing in place.
[[ stitchable ]] half4 ripple(
    float2 position,
    SwiftUI::Layer layer,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed
) {
    float distance = length(position - origin);
    float delay = distance / speed;
    time -= delay;

    // Before the ring reaches this pixel: sample the layer undisturbed
    // rather than returning transparent, which would show a bite taken out
    // of the poster on the very first frame of the animation.
    if (time < 0.0) {
        return layer.sample(position);
    }

    float rippleAmount = amplitude * sin(frequency * time) * exp(-decay * time);
    float2 n = normalize(position - origin);
    float2 newPosition = position + rippleAmount * n;

    half4 color = layer.sample(newPosition);

    // A faint brighten riding the displacement, same as the Apple sample:
    // with no highlight at all the ring reads as a lens warp rather than
    // water, since the eye has nothing to tell it energy passed through.
    color.rgb += 0.3 * (rippleAmount / amplitude) * color.a;

    return color;
}
