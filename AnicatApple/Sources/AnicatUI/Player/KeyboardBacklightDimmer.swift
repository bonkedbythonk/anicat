import Foundation
#if os(macOS)
import AppKit
import ObjectiveC.runtime
#endif

/// The four `anicat_keyboard_dim*` defaults and the "is it night" question
/// they answer.
///
/// Split out of `KeyboardBacklightDimmer` so the window arithmetic is
/// testable without a keyboard attached, and so it still compiles on iOS,
/// where the dimmer itself does not exist.
public enum KeyboardDimSchedule {
    public static let enabledKey = "anicat_keyboard_dim"
    public static let modeKey = "anicat_keyboard_dim_mode"
    public static let fromHourKey = "anicat_keyboard_dim_from"
    public static let untilHourKey = "anicat_keyboard_dim_until"

    public static let alwaysMode = "always"
    public static let nightMode = "night"
    public static let defaultFromHour = 20
    public static let defaultUntilHour = 7

    /// Half-open `[from, until)` on a 24-hour clock, wrapping across
    /// midnight when `from > until`.
    ///
    /// `from == until` is an empty window, not a whole day: the interval is
    /// half-open, and "dim around the clock" is what the Always mode is
    /// for. Reading it as 24 hours would turn a mis-set pair of steppers
    /// into a feature the user cannot see is on.
    public static func isNight(hour: Int, from: Int, until: Int) -> Bool {
        if from == until { return false }
        if from < until { return hour >= from && hour < until }
        return hour >= from || hour < until
    }

    /// Read at each dim decision rather than at `start()`, so a Settings
    /// change lands on the next idle instead of the next episode.
    public static func shouldDim(
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: enabledKey) else { return false }
        if defaults.string(forKey: modeKey) == alwaysMode { return true }
        return isNight(
            hour: calendar.component(.hour, from: now),
            from: configuredHour(fromHourKey, defaults, fallback: defaultFromHour),
            until: configuredHour(untilHourKey, defaults, fallback: defaultUntilHour)
        )
    }

    /// `integer(forKey:)` cannot tell an unset key from a stored 0, and an
    /// unset pair reads as the empty window `[0, 0)` — the toggle on and
    /// the feature silently dead until the user touches both steppers.
    private static func configuredHour(_ key: String, _ defaults: UserDefaults, fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }
}

#if os(macOS)

/// Fades the keyboard backlight out while an episode plays and puts it back
/// the instant anything is touched.
///
/// There is no public API for the keyboard backlight, so this goes through
/// CoreBrightness's `KeyboardBrightnessClient`, resolved by name at runtime
/// (`dlopen` plus `NSClassFromString`) and never linked against. Every
/// selector is checked with `responds(to:)` before its `IMP` is cast to a
/// typed C function, and a single missing name makes the whole class a
/// no-op: a convenience feature standing on a private symbol must not be
/// able to take the app down when Apple renames something.
///
/// **Why set-and-restore and not suppression.** `class_copyMethodList` on
/// `KeyboardBrightnessClient`, macOS 26.5 / Apple Silicon: there is no
/// `suppressBacklightOnKeyboard:timeout:` to prefer. The class carries
/// `setBrightness:forKeyboard:`, `setBrightness:fadeSpeed:commit:forKeyboard:`
/// and `suspendIdleDimming:forKeyboard:`; only the first is the level
/// itself, and the last suspends the system's *idle* dim rather than
/// pushing the level down. The `responds(to:)` gate below is what keeps
/// that a measurement rather than an assumption.
///
/// **Why auto-brightness is left alone.** Measured on the same machine with
/// it enabled: a written level held for the whole 600ms it was sampled, in
/// both directions (0.0 and 0.4, against an ambient level of 0.001).
/// Nothing has to be turned off for the level to stick, and disabling it
/// would be process state a crash could strand.
@MainActor
public final class KeyboardBacklightDimmer {
    /// One instance, because the backlight is one piece of hardware: a
    /// second dimmer would read the level the first had already pushed to
    /// zero and "restore" the keyboard to dark.
    public static let shared = KeyboardBacklightDimmer()

    /// Idle before the backlight goes out. Short enough to be worth having
    /// during a quiet episode, long enough that scrubbing or adjusting the
    /// volume does not flicker it.
    private let idleSeconds: TimeInterval = 3
    private let fadeDuration: TimeInterval = 0.4
    private let fadeSteps = 8
    /// The idle deadline is polled rather than re-armed per event: input
    /// arrives at trackpad rates, and rescheduling a `Timer` on every
    /// mouse-moved event costs far more than two ticks a second.
    private let pollInterval: TimeInterval = 0.5

    private let client: BrightnessClient?

    /// "Playback wants dimming" and "the dimmer is actually watching" are
    /// separate: losing focus has to restore and stand down without
    /// forgetting that an episode is still playing behind us, so
    /// `didBecomeActive` can pick it back up without RootView re-driving it.
    private var wantsDimming = false
    private var isWatching = false

    private var lastActivity = Date()
    /// The level each keyboard had when the fade started. Non-empty exactly
    /// while dimmed, which is what makes `restore()` idempotent: pause,
    /// stop and resign-active can all arrive for one edge, and a second
    /// restore would put back the level it read after the first.
    private var dimmedLevels: [UInt64: Float] = [:]
    private var idleTimer: Timer?
    private var fadeTimer: Timer?
    private var fadeStep = 0
    private var eventMonitor: Any?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// All three observers are installed once and never removed. The
    /// activation pair in particular cannot hang off `beginWatching`: the
    /// resign notification is what tears the watch down, so an observer
    /// removed alongside it would take `didBecomeActive` with it and the
    /// dimmer would never come back for the rest of the episode.
    private init() {
        client = BrightnessClient()
        // A leaked power assertion the OS cleans up on exit; a backlight
        // left at zero it does not. Quitting mid-episode leaves the keyboard
        // dark with nothing of ours still running to notice a key press.
        observe(NSApplication.willTerminateNotification) { $0.restore() }
        observe(NSApplication.didResignActiveNotification) {
            // Another app in front means the keyboard is being used for
            // something other than watching, so ours is not the state it
            // should reflect.
            $0.endWatching()
        }
        observe(NSApplication.didBecomeActiveNotification) {
            if $0.wantsDimming { $0.beginWatching() }
        }
    }

    private func observe(
        _ name: Notification.Name,
        _ handler: @escaping @Sendable @MainActor (KeyboardBacklightDimmer) -> Void
    ) {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
        )
    }

    /// Called on the playing edge. Idempotent.
    public func start() {
        guard client != nil else { return }
        wantsDimming = true
        guard NSApp?.isActive ?? false else { return }
        beginWatching()
    }

    /// Called on pause, on stop and when the stream goes away. Idempotent,
    /// and restores whether or not the backlight is currently down.
    public func stop() {
        wantsDimming = false
        endWatching()
    }

    /// Any input at all: push the idle deadline out and, if the backlight is
    /// down, bring it straight back. No fade on the way up — the point is
    /// that the keyboard is lit by the time the user has looked at it.
    public func noteUserActivity() {
        lastActivity = Date()
        restore()
    }

    /// Fades the backlight now rather than at the end of the idle window.
    ///
    /// The player's chrome fading out is a stronger signal than three
    /// seconds of no input: it means the picture is what is being looked at.
    /// Any real input still brings the light back through the monitor
    /// installed by `beginWatching`.
    public func dimNow() {
        guard isWatching else { return }
        beginFade()
    }

    // MARK: - Watching

    private func beginWatching() {
        guard !isWatching else { return }
        isWatching = true
        lastActivity = Date()
        // The dimmer carries its own monitor instead of borrowing
        // RootView's keyDown one: that monitor exists to interpret
        // shortcuts and filters events on app state, while this one only
        // has to notice that a human is present.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDragged, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.noteUserActivity() }
            return event
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func endWatching() {
        restore()
        idleTimer?.invalidate()
        idleTimer = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isWatching = false
    }

    private func tick() {
        guard isWatching, Date().timeIntervalSince(lastActivity) >= idleSeconds else { return }
        beginFade()
    }

    // MARK: - Fading

    private func beginFade() {
        guard let client, dimmedLevels.isEmpty, fadeTimer == nil else { return }
        guard KeyboardDimSchedule.shouldDim() else { return }

        // Read once here, not once per step: a step that read the level
        // back would be reading the fade's own output, and the restore
        // would put the keyboard back to whatever the last step wrote.
        var levels: [UInt64: Float] = [:]
        for id in client.keyboardIDs {
            let level = client.brightness(for: id)
            // A backlight already off has nothing to dim, and stored it
            // would become the level every later restore puts back.
            if level > 0 { levels[id] = level }
        }
        guard !levels.isEmpty else { return }
        dimmedLevels = levels
        fadeStep = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: fadeDuration / Double(fadeSteps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFade() }
        }
    }

    private func advanceFade() {
        guard let client, let fadeTimer else { return }
        fadeStep += 1
        let remaining = Float(fadeSteps - fadeStep) / Float(fadeSteps)
        for (id, level) in dimmedLevels {
            client.setBrightness(level * remaining, for: id)
        }
        if fadeStep >= fadeSteps {
            fadeTimer.invalidate()
            self.fadeTimer = nil
        }
    }

    private func restore() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let client, !dimmedLevels.isEmpty else { return }
        for (id, level) in dimmedLevels {
            _ = client.setBrightness(level, for: id)
        }
        dimmedLevels = [:]
    }
}

/// The CoreBrightness side, resolved entirely at runtime. `init?` fails
/// unless the framework loads, the class exists and all three selectors
/// answer `responds(to:)`, which is what lets the dimmer degrade to a
/// no-op instead of trapping on a nil `IMP`.
private final class BrightnessClient {
    private typealias CopyIDsFn = @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?
    private typealias BrightnessFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetBrightnessFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool

    private let instance: NSObject
    private let copyIDsSelector: Selector
    private let brightnessSelector: Selector
    private let setBrightnessSelector: Selector
    private let copyIDs: CopyIDsFn
    private let brightnessFn: BrightnessFn
    private let setBrightnessFn: SetBrightnessFn

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let instance = type.init()

        let copyIDsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
        let brightnessSelector = NSSelectorFromString("brightnessForKeyboard:")
        let setBrightnessSelector = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let copyIDsIMP = Self.implementation(on: instance, of: copyIDsSelector),
              let brightnessIMP = Self.implementation(on: instance, of: brightnessSelector),
              let setBrightnessIMP = Self.implementation(on: instance, of: setBrightnessSelector) else { return nil }

        self.instance = instance
        self.copyIDsSelector = copyIDsSelector
        self.brightnessSelector = brightnessSelector
        self.setBrightnessSelector = setBrightnessSelector
        self.copyIDs = unsafeBitCast(copyIDsIMP, to: CopyIDsFn.self)
        self.brightnessFn = unsafeBitCast(brightnessIMP, to: BrightnessFn.self)
        self.setBrightnessFn = unsafeBitCast(setBrightnessIMP, to: SetBrightnessFn.self)
    }

    /// A laptop has one, a Mac with an external keyboard can have none.
    var keyboardIDs: [UInt64] {
        // The selector is named `copy…`, so the array arrives owned:
        // `takeUnretainedValue` would leak one NSArray per dim.
        let ids = copyIDs(instance, copyIDsSelector)?.takeRetainedValue()
        return (ids as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    func brightness(for keyboardID: UInt64) -> Float {
        brightnessFn(instance, brightnessSelector, keyboardID)
    }

    @discardableResult
    func setBrightness(_ level: Float, for keyboardID: UInt64) -> Bool {
        setBrightnessFn(instance, setBrightnessSelector, max(0, min(1, level)), keyboardID).boolValue
    }

    private static func implementation(on object: NSObject, of selector: Selector) -> IMP? {
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        return method_getImplementation(method)
    }
}

#endif
