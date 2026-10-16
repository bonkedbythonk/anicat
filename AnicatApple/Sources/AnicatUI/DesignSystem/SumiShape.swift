import SwiftUI

/// The rectangle every card, button and panel is drawn from. A rounded
/// rectangle on every skin but two: Night City cuts the top-right and
/// bottom-left corners on the diagonal, Evangelion cuts all four into an
/// octagon, each by the amount the radius would have rounded them.
///
/// Whether to cut is read once, in `init`, which runs inside the owning view's
/// `body` and so is tracked by Observation. Read from `path(in:)` instead, a
/// skin switch would leave the old outline on any view whose shape value had
/// not changed, because SwiftUI does not recompute the path of an equal shape.
public struct SumiRect: InsettableShape {
    public var cornerRadius: CGFloat
    private let cut: Bool
    private let octagon: Bool
    private var insetAmount: CGFloat = 0

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        self.cut = ThemeStore.shared.palette.isCyber
        self.octagon = ThemeStore.shared.palette.isEva
    }

    public func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard cut || octagon else {
            return RoundedRectangle(cornerRadius: max(0, cornerRadius - insetAmount)).path(in: box)
        }
        let c = min(max(0, cornerRadius - insetAmount), min(box.width, box.height) / 2)
        var path = Path()
        if octagon {
            path.move(to: CGPoint(x: box.minX + c, y: box.minY))
            path.addLine(to: CGPoint(x: box.maxX - c, y: box.minY))
            path.addLine(to: CGPoint(x: box.maxX, y: box.minY + c))
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - c))
            path.addLine(to: CGPoint(x: box.maxX - c, y: box.maxY))
            path.addLine(to: CGPoint(x: box.minX + c, y: box.maxY))
            path.addLine(to: CGPoint(x: box.minX, y: box.maxY - c))
            path.addLine(to: CGPoint(x: box.minX, y: box.minY + c))
            path.closeSubpath()
            return path
        }
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - c, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY + c))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX + c, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY - c))
        path.closeSubpath()
        return path
    }

    public func inset(by amount: CGFloat) -> SumiRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Two L-shaped marks on the corners `SumiRect` leaves square.
private struct SumiBracketMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(12, min(rect.width, rect.height) / 3)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        return path
    }
}

public extension View {
    /// Corner brackets in the accent, on Night City only. A static stroke:
    /// nothing animates and nothing blurs, so it costs a scrolling grid of
    /// posters one extra path each.
    @ViewBuilder
    func sumiBrackets() -> some View {
        if ThemeStore.shared.palette.isCyber {
            overlay {
                SumiBracketMarks()
                    .stroke(SumiTheme.indigo, style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }

    /// A soft accent halo, on Night City only. Blur is the expensive part of
    /// a glow, so call sites use it on one element at a time (the hovered
    /// poster, the active sidebar row), never on every cell of a grid.
    @ViewBuilder
    func sumiGlow(radius: CGFloat, opacity: Double = 0.5) -> some View {
        if ThemeStore.shared.palette.isCyber {
            shadow(color: SumiTheme.indigo.opacity(opacity), radius: radius)
        } else {
            self
        }
    }
}

/// A progress bar cut into cells with a gap between: twelve on Night City,
/// the way the game's health bar is, and more on Evangelion, as a sync gauge.
/// Drawn once; nothing moves.
public struct CyberSegmentedBar: View {
    let fraction: CGFloat
    let cells: Int
    let tone: Color?

    public init(fraction: CGFloat, cells: Int = 12, tone: Color? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.cells = cells
        self.tone = tone
    }

    public var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(cells - 1)) / CGFloat(cells)
            let lit = Int((fraction * CGFloat(cells)).rounded(.up))
            for index in 0..<cells {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                context.fill(
                    Path(rect),
                    with: .color(index < lit ? (tone ?? SumiTheme.indigo) : Color.black.opacity(0.55))
                )
            }
        }
    }
}

/// Diagonal warning stripes in the accent over the ground. Drawn once.
public struct SumiHazard: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.85)))
            var stripes = Path()
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + 5, y: size.height))
                stripes.addLine(to: CGPoint(x: x + 5 + size.height, y: 0))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripes.closeSubpath()
                x += 10
            }
            context.fill(stripes, with: .color(SumiTheme.indigo))
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

public extension View {
    /// A second hairline frame inside the first, the way the MAGI panels are
    /// drawn, on Evangelion only.
    @ViewBuilder
    func sumiFrame(radius: CGFloat) -> some View {
        if ThemeStore.shared.palette.isEva {
            overlay {
                SumiRect(cornerRadius: radius)
                    .inset(by: 3)
                    .stroke(SumiTheme.indigo.opacity(0.4), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }

    /// Hazard stripes along the top and bottom edge, on Evangelion only: the
    /// "WARNING" banner of the show.
    @ViewBuilder
    func sumiHazardEdges() -> some View {
        if ThemeStore.shared.palette.isEva {
            overlay(alignment: .top) { SumiHazard().frame(height: 5) }
                .overlay(alignment: .bottom) { SumiHazard().frame(height: 5) }
        } else {
            self
        }
    }
}

/// The ground of a page: the palette's background colour and, when the skin's
/// art folder has a `background` picture, that picture dimmed and faded into
/// the colour toward the bottom so text over it keeps its contrast. The
/// picture is bounded by the page, not sized by it: `scaledToFill` inside a
/// bare background would push the page's layout out to the image's size.
public struct SumiGround: View {
    public init() {}

    public var body: some View {
        ZStack {
            SumiTheme.background
            if let url = SkinArt.url("background", skin: ThemeStore.shared.skin) {
                Color.clear
                    .overlay {
                        CachedAsyncImage(url: url, fit: .box(width: 2400, height: 1500)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .clipped()
                    .opacity(0.30)
                    .overlay {
                        LinearGradient(
                            colors: [SumiTheme.background.opacity(0.0), SumiTheme.background.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
    }
}

public extension View {
    func sumiGround() -> some View {
        background(SumiGround())
    }
}
