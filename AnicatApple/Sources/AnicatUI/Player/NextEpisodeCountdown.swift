import Foundation

/// The "next episode in 8…" card's state, as a value with no clock in it.
///
/// Driven by playback position rather than wall time, for two reasons. A
/// pause has to freeze the countdown, and position ticks simply stop while
/// mpv is paused, so freezing is what falling out of the tick loop already
/// does — a `Date` deadline would instead expire behind the pause and fire
/// the moment playback resumed. And a value with no clock is testable
/// without one, the same trade `SleepBlocker` makes by injecting IOKit.
///
/// The consequence, stated rather than hidden: at 2x speed the card counts
/// down in four wall-clock seconds. That matches the rest of the episode
/// running at 2x and is the behaviour a viewer at that speed wants.
public struct NextEpisodeCountdown: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case counting
        /// Dismissed for this episode. Never re-arms: a viewer who said no
        /// once should not have to say it again forty seconds later, which
        /// is what a phase that could fall back to `.idle` would do.
        case cancelled
        case fired
    }

    public static let seconds: Double = 8

    public private(set) var phase: Phase = .idle
    private var armedAt: Double = 0

    public init() {}

    /// Starts the countdown, once per episode. Answers whether it did, so a
    /// caller can tell an arm from a tick that found it already running.
    @discardableResult
    public mutating func arm(at position: Double) -> Bool {
        guard phase == .idle else { return false }
        phase = .counting
        armedAt = position
        return true
    }

    public mutating func cancel() {
        guard phase == .counting else { return }
        phase = .cancelled
    }

    /// "Play now". Answers whether the caller should start the next episode.
    @discardableResult
    public mutating func playNow() -> Bool {
        guard phase == .counting else { return false }
        phase = .fired
        return true
    }

    /// Answers whether this tick is the one that expires the countdown —
    /// true exactly once, because it moves to `.fired` on the way out.
    @discardableResult
    public mutating func advance(to position: Double) -> Bool {
        guard phase == .counting, position - armedAt >= Self.seconds else { return false }
        phase = .fired
        return true
    }

    /// Seconds left, clamped: a seek backwards while the card is up moves
    /// `position` behind `armedAt` and would otherwise read as more than the
    /// full eight.
    public func remaining(at position: Double) -> Double {
        guard phase == .counting else { return 0 }
        return min(max(Self.seconds - (position - armedAt), 0), Self.seconds)
    }

    /// 0 at the start, 1 at expiry — what the ring draws.
    public func elapsedFraction(at position: Double) -> Double {
        guard Self.seconds > 0 else { return 1 }
        return 1 - remaining(at: position) / Self.seconds
    }

    public var isVisible: Bool { phase == .counting }

    /// Anything but `.idle`. The card has already had its say for this
    /// episode, so nothing else may auto-advance it — this is what keeps
    /// `AppModel`'s own end-of-episode auto-next from firing on top of a
    /// countdown the viewer cancelled.
    public var isResolved: Bool { phase != .idle }

    public mutating func reset() {
        self = NextEpisodeCountdown()
    }
}
