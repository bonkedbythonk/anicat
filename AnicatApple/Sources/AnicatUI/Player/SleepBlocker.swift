import Foundation
#if os(macOS)
import AppKit
import IOKit.pwr_mgt
#else
import UIKit
#endif

/// Holds a power-management assertion for as long as an episode is playing.
///
/// Without one the machine treats a video as idle time: nothing in the
/// player generates input, so on a laptop the screen dims at the display
/// sleep timeout and then sleeps mid-episode, with mpv still decoding
/// underneath it. `kIOPMAssertionTypePreventUserIdleDisplaySleep` covers
/// both the display and, implicitly, system idle sleep, which is what a
/// video wants; the plain system-sleep assertion would keep the audio
/// going behind a black screen.
///
/// `hold` and `release` are idempotent. `PlayerController.isPlaying` is
/// written from four places and `stopPlayback` runs on top of whatever the
/// last pause did, so the same edge can arrive twice; a naive
/// create-per-hold leaked an assertion on each duplicate and a
/// release-per-release handed IOKit an id it had already freed.
///
/// The IOKit calls are injected so a test can drive the state machine with
/// a counter instead of the kernel.
public final class SleepBlocker: @unchecked Sendable {
    public typealias AssertionID = UInt32
    public typealias Create = @Sendable (_ reason: String) -> AssertionID?
    public typealias Release = @Sendable (AssertionID) -> Void

    private let create: Create
    private let releaseAssertion: Release
    private let lock = NSLock()
    private var held: (id: AssertionID, reason: String)?
    private var terminationObserver: NSObjectProtocol?

    public init(create: @escaping Create, release: @escaping Release) {
        self.create = create
        self.releaseAssertion = release
        #if os(macOS)
        // Process exit frees an assertion on its own; releasing on
        // `willTerminate` keeps the drop on our side of the boundary, where
        // it is ordered before AppKit's teardown rather than after whatever
        // that teardown still runs with a video that is already gone.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.release()
        }
        #endif
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        release()
    }

    /// The real thing, backed by `IOPMAssertionCreateWithName`.
    public static func system() -> SleepBlocker {
        #if os(macOS)
        return SleepBlocker(
            create: { reason in
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &id
                )
                guard result == kIOReturnSuccess else {
                    print("[sleep] IOPMAssertionCreateWithName failed: \(result)")
                    return nil
                }
                return id
            },
            release: { id in
                IOPMAssertionRelease(id)
            }
        )
        #else
        // iOS has no assertion object: the idle timer is one process-wide
        // flag, so the id is a constant that exists only to drive the same
        // held/not-held state machine the IOKit path uses. Returning nil
        // instead would leave `isHolding` false forever and every release
        // a no-op.
        return SleepBlocker(
            create: { _ in
                setIdleTimerDisabled(true)
                return 1
            },
            release: { _ in
                setIdleTimerDisabled(false)
            }
        )
        #endif
    }

    #if !os(macOS)
    /// `UIApplication` is main-actor isolated and `hold`/`release` are called
    /// from whatever thread the playback state changed on. Plain
    /// `DispatchQueue.main.async` rather than a `Task`: the main queue is
    /// FIFO, so a hold immediately followed by a release cannot land
    /// inverted and leave the screen pinned awake after playback stopped.
    private static func setIdleTimerDisabled(_ disabled: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UIApplication.shared.isIdleTimerDisabled = disabled
            }
        }
    }
    #endif

    public var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held != nil
    }

    public var currentReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return held?.reason
    }

    /// Acquires the assertion, or swaps it for one with the new reason when
    /// the episode changed under a hold that never dropped (auto-next keeps
    /// `isPlaying` true across the transition). The reason is what
    /// `pmset -g assertions` prints, so it names the episode.
    public func hold(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if let held {
            if held.reason == reason { return }
            releaseAssertion(held.id)
            self.held = nil
        }
        if let id = create(reason) {
            held = (id, reason)
        }
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let held else { return }
        releaseAssertion(held.id)
        self.held = nil
    }
}
