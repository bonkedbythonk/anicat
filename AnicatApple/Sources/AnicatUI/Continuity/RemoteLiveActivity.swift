#if os(iOS)
import ActivityKit
import AnicatRemoteActivity
import Foundation

/// Keeps a Live Activity in step with what the Mac is playing.
///
/// A Live Activity and not a Now Playing tile: iOS gives that slot to
/// whichever app holds an active audio session, and this one plays no audio.
/// The only way to claim it is to loop a silent track, which takes audio
/// focus from whatever the person is actually listening to -- a remote is not
/// worth silencing a podcast for.
@MainActor
public final class RemoteLiveActivity {
    public static let shared = RemoteLiveActivity()
    private init() {}

    private var activity: Activity<RemoteActivityAttributes>?
    /// The last state pushed, so an unchanged 1 Hz tick does not become a
    /// system update every second for the length of an episode.
    private var lastState: RemoteActivityAttributes.ContentState?
    /// The Mac an activity started from here will name. Set by `sync` before
    /// the request, because the request itself happens a hop later.
    private var pendingHostName = "the Mac"

    /// Wires the Live Activity's buttons to the socket. Called once, from
    /// the app: `LiveActivityIntent.perform` runs in this process, so this is
    /// where the handler has to live.
    public func installIntentHandler() {
        RemoteActivityBridge.shared.handler = { command in
            Task { @MainActor in
                switch command {
                case .playPause: RemoteClient.shared.send(.playPause)
                case .back10: RemoteClient.shared.send(.seekBy(-10))
                case .forward10: RemoteClient.shared.send(.seekBy(10))
                case .skipWindow: RemoteClient.shared.send(.skipPendingWindow)
                }
            }
        }
    }

    /// Called on every state frame. Starts, updates or ends the activity to
    /// match, so nothing else has to track whether one is running.
    public func sync(state: RemoteState, hostName: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        pendingHostName = hostName ?? "the Mac"
        guard state.hasPlayback else {
            end()
            return
        }
        let content = RemoteActivityAttributes.ContentState(
            title: state.title,
            subtitle: state.episodeTitle.isEmpty
                ? "Episode \(state.episodeNumber)"
                : "Episode \(state.episodeNumber) - \(state.episodeTitle)",
            isPlaying: state.isPlaying,
            currentTime: state.currentTime,
            duration: state.duration,
            skipLabel: state.skipLabel
        )
        guard content != lastState else { return }
        lastState = content
        // Hopped through a task rather than awaited here because `sync` is
        // called from a socket callback that cannot be async. `Activity` is
        // not `Sendable`, so the work stays on this actor and only the
        // content -- which is -- crosses into ActivityKit.
        Task { @MainActor [weak self] in await self?.push(content) }
    }

    private func push(_ content: RemoteActivityAttributes.ContentState) async {
        // `nonisolated(unsafe)`: `Activity` is not `Sendable`, and its own
        // `update`/`end` are nonisolated async, so any call from an actor is
        // read as sending the handle off it. The handle is only ever touched
        // from this MainActor class, which the compiler cannot see through
        // ActivityKit's signatures.
        if let activity {
            nonisolated(unsafe) let handle = activity
            await handle.update(ActivityContent(state: content, staleDate: nil))
        } else {
            activity = try? Activity.request(
                attributes: RemoteActivityAttributes(hostName: pendingHostName),
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil
            )
        }
    }

    public func end() {
        guard activity != nil else { return }
        lastState = nil
        Task { @MainActor [weak self] in await self?.endNow() }
    }

    private func endNow() async {
        guard let activity else { return }
        self.activity = nil
        nonisolated(unsafe) let handle = activity
        await handle.end(nil, dismissalPolicy: .immediate)
    }
}
#endif
