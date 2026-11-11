#if os(tvOS)
import SwiftUI
import UIKit

/// What the Up Next backdrop shows: a title's wide banner, or, when no
/// banner is known, its cover blurred past recognition. Shelf cards carry no
/// banner (`MediaSummary` has none), so only a title that has been opened
/// once, or the hero's queue entry, gets the real one.
struct TVBackdropSource: Hashable {
    let url: URL
    let isBanner: Bool

    init?(banner: URL?, cover: URL?) {
        if let banner {
            url = banner
            isBanner = true
        } else if let cover {
            url = cover
            isBanner = false
        } else {
            return nil
        }
    }

    /// A blurred cover needs no detail, and a 1920px decode per focus step
    /// is what the A15 would otherwise pay while scrubbing along a row.
    var pixels: CGFloat { isBanner ? 1920 : 360 }
}

/// The full-screen picture behind Up Next, fixed while the shelves scroll
/// over it, faded into the ground on the left and at the bottom so the
/// hero's text and the rows stay readable.
///
/// A new source is shown only once its image is decoded: `CachedAsyncImage`
/// paints its placeholder between URLs, and swapping the URL directly
/// flashed the ground between two pictures. Focus changes are also held for
/// a moment, so scrubbing along a row decodes the card it stops on rather
/// than every card it passes.
struct TVBackdrop: View {
    let source: TVBackdropSource?
    @State private var shown: TVBackdropSource?
    /// The shown picture's hue, as `PosterAccent` derives it for the Mac's
    /// detail page. Glows up from the bottom of the black so the ground
    /// under the rows carries the show's colour instead of being flat.
    @State private var glow: Color?

    var body: some View {
        ZStack {
            SumiTheme.background
            if let shown {
                Color.clear
                    .overlay {
                        CachedAsyncImage(url: shown.url, maxPixelSize: shown.pixels) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                                .blur(radius: shown.isBanner ? 0 : 60)
                                .opacity(shown.isBanner ? 1 : 0.7)
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .clipped()
                    .id(shown)
                    .transition(.opacity)
            }
            LinearGradient(
                stops: [
                    .init(color: SumiTheme.background.opacity(0.92), location: 0),
                    .init(color: SumiTheme.background.opacity(0.5), location: 0.4),
                    .init(color: .clear, location: 0.7),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: SumiTheme.background, location: 0.72),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            if let glow {
                RadialGradient(
                    colors: [glow.opacity(0.28), glow.opacity(0.08), .clear],
                    center: .bottom,
                    startRadius: 0,
                    endRadius: 1300
                )
                .transition(.opacity)
                .id(glow)
            }
        }
        .ignoresSafeArea()
        .task(id: source) {
            guard let source else { return }
            if shown != nil {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            let image = await ImageDecodeCache.shared.image(for: source.url, maxPixelSize: source.pixels)
            guard !Task.isCancelled else { return }
            let hue = image.flatMap { PosterAccent.accent(for: $0, isLight: ThemeStore.shared.palette.isLight) }
            withAnimation(.sumi(.page)) {
                shown = source
                glow = hue
            }
        }
    }
}

/// The top of Up Next: the title to go back to, with Resume already under
/// the remote's thumb. Platform buttons, not a house style: a custom style
/// on tvOS draws no focus effect at all.
struct TVShowcaseHero: View {
    let eyebrow: String
    let title: String
    let meta: String
    let primaryLabel: String
    let primary: () -> Void
    let details: () -> Void
    let onFocus: () -> Void

    private enum Control: Hashable { case primary, details }
    @FocusState private var focused: Control?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(eyebrow)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(SumiTheme.muted)
            Text(title)
                .font(.sumiHeading(size: 68, weight: .bold))
                .foregroundStyle(SumiTheme.foreground)
                .lineLimit(2)
            Text(meta)
                .font(.system(size: 26)).monospacedDigit()
                .foregroundStyle(SumiTheme.foreground.opacity(0.8))
                .lineLimit(1)
            HStack(spacing: 24) {
                Button(action: primary) {
                    Label(primaryLabel, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(SumiTheme.indigo)
                .focused($focused, equals: .primary)
                Button("Episodes", action: details)
                    .focused($focused, equals: .details)
            }
            .padding(.top, 12)
            // Focus arriving from outside the hero goes to Resume. The
            // engine picks the nearest button, and a press down from the
            // "Up Next" tab landed on Episodes; `defaultFocus`, with or
            // without `.userInitiated` and its own focus scope, did not
            // change that in the tvOS 27 simulator.
            .onChange(of: focused) { previous, control in
                if previous == nil, control == .details {
                    focused = .primary
                }
                if control != nil { onFocus() }
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .frame(minHeight: 520, alignment: .bottomLeading)
        .padding(.horizontal, TVMetrics.gutter)
        .focusSection()
    }
}

/// The tab bar as quiet words over the picture, as in the showcase mock:
/// no bar behind it and no pill on the selected tab, the selected word in
/// the foreground colour and the rest muted. Focus keeps tvOS's own
/// highlight, which is how the viewer finds the remote's place. The native
/// bar stays (rather than a row of custom buttons) for its focus routing
/// and for hiding itself as the shelves scroll.
///
/// Set through `UITabBar.appearance()` because SwiftUI's `TabView` has no
/// such styling on tvOS. Read once, when the root is built: a skin chosen
/// later recolours the words on the next launch.
@MainActor
enum TVTabBarStyle {
    static func apply() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.selectionIndicatorTintColor = .clear
        let font = UIFont.systemFont(ofSize: 30, weight: .semibold)
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor(SumiTheme.muted), .font: font]
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor(SumiTheme.foreground), .font: font]
            // On tvOS's white focus pill: the light foreground vanished on it.
            layout.focused.titleTextAttributes = [.foregroundColor: UIColor.black, .font: font]
        }
        UITabBar.appearance().standardAppearance = appearance
    }
}

/// Runs `action` when this view takes focus. `onFocusChange` is not in the
/// tvOS SDK, so it is a `@FocusState` per view instead.
private struct TVOnFocus: ViewModifier {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { action() }
            }
    }
}

extension View {
    func tvOnFocus(_ action: @escaping () -> Void) -> some View {
        modifier(TVOnFocus(action: action))
    }
}
#endif
