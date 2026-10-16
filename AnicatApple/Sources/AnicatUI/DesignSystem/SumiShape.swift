import SwiftUI

/// The rectangle every card, button and panel is drawn from. A rounded
/// rectangle on every skin but Night City, where the top-right and bottom-left
/// corners are cut on the diagonal by the same amount the radius would have
/// rounded them.
///
/// Whether to cut is read once, in `init`, which runs inside the owning view's
/// `body` and so is tracked by Observation. Read from `path(in:)` instead, a
/// skin switch would leave the old outline on any view whose shape value had
/// not changed, because SwiftUI does not recompute the path of an equal shape.
public struct SumiRect: InsettableShape {
    public var cornerRadius: CGFloat
    private let cut: Bool
    private var insetAmount: CGFloat = 0

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        self.cut = ThemeStore.shared.palette.isCyber
    }

    public func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard cut else {
            return RoundedRectangle(cornerRadius: max(0, cornerRadius - insetAmount)).path(in: box)
        }
        let c = min(cornerRadius, min(box.width, box.height) / 2)
        var path = Path()
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
