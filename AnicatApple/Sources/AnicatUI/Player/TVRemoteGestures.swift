#if os(tvOS)
import SwiftUI
import UIKit

/// The parts of the Siri Remote SwiftUI cannot tell apart. `onMoveCommand`
/// fires the same for a click on the clickpad's edge and for a swipe across
/// it, and never says how long a click was held. Recognizers on the window
/// see the press types and the touch surface itself:
///
/// - a click held on the left or right edge (`onHold`, began and ended),
/// - a click on an edge, without the swipes that also move focus (`onEdgeClick`),
/// - a click on the centre (`onSelect`),
/// - a swipe's travel across the surface (`onPan`).
///
/// Each is switched on by the player only in the state that uses it, so the
/// focus engine keeps the remote everywhere else.
struct TVRemoteGestures: UIViewRepresentable {
    var holdEnabled: Bool
    var clicksEnabled: Bool
    var selectEnabled: Bool
    var panEnabled: Bool
    var onHold: (_ direction: Double, _ began: Bool) -> Void
    var onEdgeClick: (_ direction: Double) -> Void
    var onSelect: () -> Void
    var onPan: (_ translation: CGFloat, _ velocity: CGFloat, _ state: UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.holdLeft.isEnabled = holdEnabled
        coordinator.holdRight.isEnabled = holdEnabled
        coordinator.clickLeft.isEnabled = clicksEnabled
        coordinator.clickRight.isEnabled = clicksEnabled
        coordinator.select.isEnabled = selectEnabled
        coordinator.pan.isEnabled = panEnabled
    }

    static func dismantleUIView(_ view: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Attaches the recognizers to its window rather than to itself: presses
    /// go to the focused view and up its chain, which ends at the window,
    /// and this view is never the focused one.
    final class HostView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TVRemoteGestures?
        private weak var window: UIWindow?

        lazy var holdLeft = longPress(.leftArrow, #selector(heldLeft))
        lazy var holdRight = longPress(.rightArrow, #selector(heldRight))
        lazy var clickLeft = tap(.leftArrow, #selector(clickedLeft))
        lazy var clickRight = tap(.rightArrow, #selector(clickedRight))
        lazy var select = tap(.select, #selector(selected))
        lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned))
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        private var all: [UIGestureRecognizer] { [holdLeft, holdRight, clickLeft, clickRight, select, pan] }

        func attach(to window: UIWindow?) {
            guard let window, window !== self.window else { return }
            detach()
            self.window = window
            all.forEach(window.addGestureRecognizer)
        }

        func detach() {
            guard let window else { return }
            all.forEach(window.removeGestureRecognizer)
            self.window = nil
        }

        private func longPress(_ type: UIPress.PressType, _ action: Selector) -> UILongPressGestureRecognizer {
            let recognizer = UILongPressGestureRecognizer(target: self, action: action)
            recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
            recognizer.minimumPressDuration = 0.45
            recognizer.delegate = self
            return recognizer
        }

        private func tap(_ type: UIPress.PressType, _ action: Selector) -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: action)
            recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
            recognizer.delegate = self
            return recognizer
        }

        // Alongside the focus engine and each other: a hold must not stop
        // the first click's seek, and a pan must not swallow a press.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func heldLeft(_ g: UILongPressGestureRecognizer) { hold(-1, g.state) }
        @objc private func heldRight(_ g: UILongPressGestureRecognizer) { hold(1, g.state) }
        private func hold(_ direction: Double, _ state: UIGestureRecognizer.State) {
            switch state {
            case .began: parent?.onHold(direction, true)
            case .ended, .cancelled, .failed: parent?.onHold(direction, false)
            default: break
            }
        }

        @objc private func clickedLeft() { parent?.onEdgeClick(-1) }
        @objc private func clickedRight() { parent?.onEdgeClick(1) }
        @objc private func selected() { parent?.onSelect() }

        @objc private func panned(_ g: UIPanGestureRecognizer) {
            parent?.onPan(g.translation(in: g.view).x, g.velocity(in: g.view).x, g.state)
        }
    }
}
#endif
