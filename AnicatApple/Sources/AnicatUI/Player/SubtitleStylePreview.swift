import SwiftUI
import CoreText

/// What a subtitle style looks like, drawn by SwiftUI rather than by mpv, so
/// Settings and the player's menu can show it without a video playing.
///
/// An approximation, not mpv's renderer: the outline is eight hard shadows
/// around the glyphs, which reads the same at preview size. Sizes are
/// relative to a 720-line frame, so a preview of height `h` scales
/// everything by `h / 720`.
///
/// The size is what real releases use, and it is a line height, not a point
/// size. SubsPlease writes its dialogue at 26 in a 360-line script, 52 at
/// 720; a YURI BD release, 50 at 720 (both read from files in the stream
/// cache, 2026-09-22). libass sizes a font so ascent plus descent equals
/// that number, while SwiftUI's size is the em; for these fonts ascent plus
/// descent is 1.12 to 1.17 em (CoreText, per 100pt: Trebuchet MS 116.1,
/// Helvetica Neue 116.5, Arial 111.7, Roboto about 117). Drawn as a point
/// size, every preview came out a step too large.
struct SubtitleSample: View {
    let style: SubtitleStyle
    var scale: Double = 1
    /// Height of the frame the sample stands for, in points.
    var frameHeight: CGFloat
    var text: String = "I'll protect everyone. That's a promise."

    var body: some View {
        let look = style.look ?? SubtitleStyle.releaseLook
        let unit = frameHeight / 720
        // `Look` is in 360-line units; the preview frame is laid out in 720.
        let lineHeight = look.size.map { CGFloat($0) * 2 } ?? Self.releaseLineHeight
        let size = lineHeight * unit * CGFloat(scale) / Self.lineHeightPerEm(look.font)
        let outline = max(CGFloat(look.outlineWidth) * 2 * unit, look.boxed ? 0 : 0.6)
        Text(text)
            .font(fontFor(look, size: size))
            .foregroundColor(Color(argb: look.text))
            .multilineTextAlignment(.center)
            .modifier(Outline(color: Color(argb: look.outline), width: look.boxed ? 0 : outline))
            .shadow(
                color: Color(argb: look.shadow),
                radius: 0,
                x: CGFloat(look.shadowOffset) * 2 * unit,
                y: CGFloat(look.shadowOffset) * 2 * unit
            )
            .padding(.horizontal, look.boxed ? outline + 2 : 0)
            .padding(.vertical, look.boxed ? outline * 0.5 + 1 : 0)
            .background(look.boxed ? Color(argb: look.outline) : .clear)
            .accessibilityLabel("Sample subtitle in the \(style.label) style")
    }

    /// A typical release's dialogue line height, in 720-line units.
    static let releaseLineHeight: CGFloat = 52

    /// Ascent plus descent per em, as libass measures a font. "sans-serif"
    /// stands for the release's own font, which on this Mac resolves to
    /// Helvetica (1.00) while the fonts releases actually ship, Roboto and
    /// its kind, are about 1.17.
    static func lineHeightPerEm(_ name: String) -> CGFloat {
        guard name != "sans-serif" else { return 1.17 }
        let font = CTFontCreateWithName(name as CFString, 100, nil)
        let cell = CTFontGetAscent(font) + CTFontGetDescent(font)
        return cell > 0 ? cell / 100 : 1.17
    }

    private func fontFor(_ look: SubtitleStyle.Look, size: CGFloat) -> Font {
        let base: Font = look.font == "sans-serif" ? .system(size: size) : .custom(look.font, size: size)
        return look.bold ? base.weight(.bold) : base
    }

    /// Eight hard shadows, one per compass point: the cheapest outline
    /// SwiftUI can draw around text, and at preview sizes indistinguishable
    /// from libass's stroked glyph edge.
    private struct Outline: ViewModifier {
        let color: Color
        let width: CGFloat

        func body(content: Content) -> some View {
            if width <= 0 {
                content
            } else {
                content
                    .shadow(color: color, radius: 0, x: width, y: 0)
                    .shadow(color: color, radius: 0, x: -width, y: 0)
                    .shadow(color: color, radius: 0, x: 0, y: width)
                    .shadow(color: color, radius: 0, x: 0, y: -width)
                    .shadow(color: color, radius: 0, x: width * 0.7, y: width * 0.7)
                    .shadow(color: color, radius: 0, x: -width * 0.7, y: -width * 0.7)
                    .shadow(color: color, radius: 0, x: width * 0.7, y: -width * 0.7)
                    .shadow(color: color, radius: 0, x: -width * 0.7, y: width * 0.7)
            }
        }
    }
}

extension SubtitleStyle {
    /// mpv's own defaults for text subtitles, which is what "Release
    /// default" looks like on a release that brings no styling of its own.
    static let releaseLook = Look(
        font: "sans-serif", size: nil, bold: false, text: 0xFFFFFFFF, outline: 0xFF000000,
        outlineWidth: 1.3, shadow: 0x00000000, shadowOffset: 0, boxed: false
    )
}

extension Color {
    /// `0xAARRGGBB`, alpha as opacity: the same encoding `SubtitleStyle.Look`
    /// uses for mpv.
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }
}

/// A stand-in frame for the sample to sit on: a dusk sky with a bright
/// horizon, so a white or yellow line has to hold up against light and dark
/// at once the way it does over real footage. The sign in the corner is
/// drawn the same in every style on purpose: it is what the note under the
/// picker promises, that signs keep the release's own look.
struct SubtitleScene: View {
    let style: SubtitleStyle
    var scale: Double = 1
    var showsSign = true

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.16, blue: 0.33),
                        Color(red: 0.52, green: 0.36, blue: 0.52),
                        Color(red: 0.96, green: 0.70, blue: 0.45),
                        Color(red: 0.30, green: 0.26, blue: 0.30),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // A horizon line and a couple of silhouettes, so the frame
                // reads as a shot rather than as a gradient swatch.
                Ellipse()
                    .fill(Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.85))
                    .frame(width: height * 0.34, height: height * 0.34)
                    .position(x: geometry.size.width * 0.72, y: height * 0.56)
                Rectangle()
                    .fill(Color(red: 0.16, green: 0.13, blue: 0.18))
                    .frame(height: height * 0.3)
                    .position(x: geometry.size.width / 2, y: height * 0.85)
                if showsSign {
                    Text("第3話  THE PROMISE")
                        .font(.custom("Georgia", size: height * 0.07).italic())
                        .foregroundColor(Color(red: 0.98, green: 0.93, blue: 0.80))
                        .shadow(color: Color(red: 0.35, green: 0.12, blue: 0.10), radius: 0, x: 1, y: 1)
                        .position(x: geometry.size.width * 0.28, y: height * 0.14)
                }
                VStack {
                    Spacer()
                    SubtitleSample(style: style, scale: scale, frameHeight: height)
                        .padding(.horizontal, geometry.size.width * 0.06)
                        .padding(.bottom, height * 0.07)
                }
            }
            .clipped()
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The five looks as tiles, each drawn in its own style, so the choice is
/// made by what it looks like rather than by a name. `compact` is the
/// player's menu: a short "Aa" instead of a scene, to fit five across 330pt.
struct SubtitleStyleTiles: View {
    @Binding var selection: SubtitleStyle
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            ForEach(SubtitleStyle.allCases) { style in
                Button {
                    selection = style
                } label: {
                    VStack(spacing: compact ? 4 : 6) {
                        tileBody(style)
                        Text(style.label)
                            .font(.system(size: compact ? 9.5 : 11, weight: selection == style ? .semibold : .regular))
                            .foregroundColor(selection == style ? SumiTheme.foreground : SumiTheme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(compact ? 3 : 4)
                    .background(
                        RoundedRectangle(cornerRadius: compact ? 7 : 10)
                            .stroke(selection == style ? SumiTheme.indigo : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(style.summary)
                .accessibilityLabel(style.label)
                .accessibilityHint(style.summary)
                .accessibilityAddTraits(selection == style ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func tileBody(_ style: SubtitleStyle) -> some View {
        if compact {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.52, green: 0.36, blue: 0.52), Color(red: 0.96, green: 0.70, blue: 0.45)],
                        startPoint: .top, endPoint: .bottom
                    ))
                SubtitleSample(style: style, frameHeight: 150, text: "Aa")
            }
            .frame(height: 34)
        } else {
            SubtitleScene(style: style, showsSign: false)
        }
    }
}
