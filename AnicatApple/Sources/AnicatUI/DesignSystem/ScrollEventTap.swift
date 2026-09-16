import Foundation
import SwiftUI
#if os(macOS)
import AppKit

/// Scroll-wheel events for gesture code, from a listen-only CGEvent tap.
///
/// Since the app put SwiftUI's scroll views on AppKit's responsive scrolling
/// path, trackpad scrolling is tracked on the event thread and a local
/// `NSEvent` monitor no longer sees it: 2 events of 133 in a test view,
/// against 133 of 133 for a session-level tap on the same gesture. The
/// tap is listen-only, so nothing here can swallow or alter an event; it
/// only tells subscribers what the trackpad did. Created on the first
/// subscriber, torn down with the last, delivered on the main run loop,
/// and only while this app is active.
@MainActor
public final class ScrollEventTap {
    public static let shared = ScrollEventTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handlers: [UUID: (NSEvent) -> Void] = [:]

    private init() {}

    public func subscribe(_ handler: @escaping (NSEvent) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        if tap == nil { install() }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        handlers[id] = nil
        if handlers.isEmpty { uninstall() }
    }

    private func install() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, cgEvent, _ in
            // The system disables a tap whose callback runs long; re-enable
            // rather than losing every gesture until relaunch.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { ScrollEventTap.shared.reenable() }
                return Unmanaged.passUnretained(cgEvent)
            }
            MainActor.assumeIsolated { ScrollEventTap.shared.deliver(cgEvent) }
            return Unmanaged.passUnretained(cgEvent)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            // No tap (a locked-down account, or a future macOS asking for a
            // permission): gestures that depend on it stay off rather than
            // crash. The rest of the app is unaffected.
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func deliver(_ cgEvent: CGEvent) {
        guard NSApp.isActive, !handlers.isEmpty, let event = NSEvent(cgEvent: cgEvent) else { return }
        if event.phase == .began { ScrollLagProbe.gestureBegan() }
        let start = CFAbsoluteTimeGetCurrent()
        for handler in handlers.values { handler(event) }
        let cost = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if event.phase == .began || cost > 2 {
            PlayerLog.write(String(format: "[scroll] tap handlers %.2fms at phase %@ dy %.1f", cost, event.phase == .began ? "began" : "changed", event.scrollingDeltaY))
        }
    }
}

/// Diagnostic for "a hard scroll lags before it moves" (owner, 2026-09-14):
/// the trackpad's `began` tick, stamped by the event tap, against the first
/// content offset change the page reports. The gap is the lag.
@MainActor
public enum ScrollLagProbe {
    private static var began: CFAbsoluteTime = 0
    private static var reported = false

    static func gestureBegan() {
        began = CFAbsoluteTimeGetCurrent()
        reported = false
    }

    public static func contentMoved(_ page: String) {
        guard began > 0, !reported else { return }
        reported = true
        PlayerLog.write(String(format: "[scroll] %@ first moved %.1fms after gesture began", page, (CFAbsoluteTimeGetCurrent() - began) * 1000))
    }
}

public extension View {
    /// Reports the page's first offset change of each gesture to `ScrollLagProbe`.
    func scrollLagProbe(_ page: String) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in
            ScrollLagProbe.contentMoved(page)
        }
    }
}
#else
public extension View {
    func scrollLagProbe(_ page: String) -> some View { self }
}
#endif
