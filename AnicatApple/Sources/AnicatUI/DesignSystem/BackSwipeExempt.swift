import SwiftUI

#if os(macOS)
/// Window frames of the sideways scrollers a back-swipe must leave alone.
@MainActor
enum BackSwipeExemptRegions {
    static var frames: [UUID: CGRect] = [:]
}

private struct BackSwipeExempt: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                BackSwipeExemptRegions.frames[id] = frame
            }
            .onDisappear { BackSwipeExemptRegions.frames[id] = nil }
    }
}
#endif

extension View {
    /// Marks a sideways scroller: a trackpad scroll that starts over it is
    /// never read as a back-swipe. No-op on iOS, which has no such gesture.
    @ViewBuilder
    func backSwipeExempt() -> some View {
        #if os(macOS)
        modifier(BackSwipeExempt())
        #else
        self
        #endif
    }
}
