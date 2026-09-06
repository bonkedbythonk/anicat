import Foundation
import MediaPlayer
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Publishes the playing episode to the system's Now Playing surface (the
/// Control Center tile, the Touch Bar strip, AirPods and headset buttons,
/// the F8 play/pause key) and routes the commands that come back from it
/// into `PlayerController`.
///
/// Media keys reach an app through `MPRemoteCommandCenter` only after that
/// app has both set `nowPlayingInfo` and reported `playbackState == .playing`;
/// until then the key event goes to whichever other app last did. That is
/// why `AppModel.resolveAndPlay` calls `setTrack` the moment it has a stream
/// URL, before mpv has opened the file or drawn a frame: publishing on the
/// first position tick instead would leave the opening seconds of every
/// episode as a window in which the play key still drives whatever app
/// held the tile before.
///
/// Not `@MainActor`: `AppModel`, which drives it, is not isolated either and
/// runs on the main thread by convention, and every `MPNowPlayingInfoCenter`
/// call is thread-safe. Remote command handlers arrive on the main thread.
public final class NowPlayingBridge: @unchecked Sendable {
    /// What the Now Playing tile names, independent of the timeline.
    public struct Track: Equatable, Sendable {
        public var title: String
        public var episodeNumber: Int
        public var episodeTitle: String

        public init(title: String, episodeNumber: Int, episodeTitle: String) {
            self.title = title
            self.episodeNumber = episodeNumber
            self.episodeTitle = episodeTitle
        }
    }

    /// Same step as the player's own skip buttons and the left/right arrow
    /// shortcuts, so a headset's double-tap and the on-screen button land
    /// on the same frame.
    public static let skipInterval: TimeInterval = 10

    /// Artwork is requested at up to this many pixels on its longest side.
    /// 600 is the key the detail page's poster (`MediaDetailView`) already
    /// decodes under, so playing from an open page is a cache hit and a
    /// second decode of the same JPEG is avoided; a different size would be
    /// a second entry per cover.
    static let artworkPixelSize: CGFloat = 600

    public static func subtitle(episodeNumber: Int, episodeTitle: String) -> String {
        let trimmed = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Episode \(episodeNumber)" : "Episode \(episodeNumber) - \(trimmed)"
    }

    /// The full `nowPlayingInfo` dictionary for a state. Pure, so a test can
    /// check it without a MediaPlayer session; `setTrack` publishes exactly
    /// this plus artwork.
    public static func info(track: Track, elapsed: Double, duration: Double, rate: Double) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: subtitle(episodeNumber: track.episodeNumber, episodeTitle: track.episodeTitle),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(elapsed, 0),
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        // A zero duration is "unknown" to AniList's runtime fallback but a
        // zero-length bar to the tile, with the elapsed time drawn past its
        // end. Leave the key out until mpv reports a real one.
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        return info
    }

    private weak var controller: PlayerController?
    private var registeredTargets: [(MPRemoteCommand, Any)] = []
    /// The dictionary as last published, kept so the per-second tick can
    /// change three keys and hand the same object back rather than
    /// rebuilding it from the controller each time.
    private var info: [String: Any] = [:]
    /// What this bridge last published, for tests. `MPNowPlayingInfoCenter`
    /// is one object per process, and the suites run in parallel: an
    /// `AppModel` constructed by another test reaches `stopPlayback`, which
    /// clears the centre from under a test that had just published to it.
    /// Asserting on the bridge's own copy is deterministic.
    var lastPublished: [String: Any]? { track == nil ? nil : info }
    private var track: Track?
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?

    public init() {}

    deinit {
        artworkTask?.cancel()
    }

    // MARK: Publishing

    /// Names the episode and starts (or restarts) the tile. `coverURL` is
    /// fetched through the app's image cache and attached when it lands;
    /// the tile shows text-only until then rather than waiting on it.
    public func setTrack(_ newTrack: Track, elapsed: Double, duration: Double, rate: Double, coverURL: URL?) {
        track = newTrack
        var next = Self.info(track: newTrack, elapsed: elapsed, duration: duration, rate: rate)
        if coverURL == artworkURL, let artwork = info[MPMediaItemPropertyArtwork] {
            next[MPMediaItemPropertyArtwork] = artwork
        }
        info = next
        publish()
        setPlaybackState(rate > 0 ? .playing : .paused)
        if coverURL != artworkURL {
            artworkURL = coverURL
            loadArtwork(from: coverURL)
        }
    }

    /// The per-second path. Only the timeline keys change; artwork and
    /// titles are left as they are.
    public func updateProgress(elapsed: Double, duration: Double, rate: Double) {
        guard track != nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(elapsed, 0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        publish()
        setPlaybackState(rate > 0 ? .playing : .paused)
    }

    /// Greys out next/previous on the tile when the episode list has no
    /// neighbour, mirroring `PlayerController.hasNextEpisode` and
    /// `hasPreviousEpisode` (whose methods also refuse, so a stale enabled
    /// state would only be cosmetic).
    public func setNavigation(hasNext: Bool, hasPrevious: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = hasPrevious
    }

    /// Takes the tile down. Clearing `nowPlayingInfo` alone leaves the
    /// system showing the last episode as paused indefinitely and still
    /// routing media keys here; `.stopped` is what hands them back.
    public func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        track = nil
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setPlaybackState(.stopped)
    }

    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setPlaybackState(_ state: MPNowPlayingPlaybackState) {
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = state
        #endif
    }

    // MARK: Artwork

    private func loadArtwork(from url: URL?) {
        artworkTask?.cancel()
        artworkTask = nil
        info[MPMediaItemPropertyArtwork] = nil
        guard let url else { return }
        let size = Self.artworkPixelSize
        artworkTask = Task { [weak self] in
            guard let image = await ImageDecodeCache.shared.image(for: url, maxPixelSize: size) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.artworkURL == url else { return }
                self.info[MPMediaItemPropertyArtwork] = Self.artwork(from: image)
                self.publish()
            }
        }
    }

    /// The one place `PlatformImage` is not enough: the request handler's
    /// return type is the same typealias on both platforms, but only
    /// `NSImage` takes the point size at construction — a `UIImage` carries
    /// its scale instead, and the tile derives the size from the CGImage.
    private static func artwork(from image: CGImage) -> MPMediaItemArtwork {
        let bounds = CGSize(width: image.width, height: image.height)
        #if canImport(AppKit)
        return MPMediaItemArtwork(boundsSize: bounds) { _ in
            PlatformImage(cgImage: image, size: bounds)
        }
        #else
        return MPMediaItemArtwork(boundsSize: bounds) { _ in
            PlatformImage(cgImage: image)
        }
        #endif
    }

    // MARK: Remote commands

    /// Points the system's transport commands at `controller`. Safe to call
    /// on every play: an existing registration is replaced, not stacked,
    /// because two targets on one command both fire and a single pause press
    /// toggled twice back to playing.
    public func attach(to controller: PlayerController) {
        if self.controller === controller, !registeredTargets.isEmpty { return }
        detachCommands()
        self.controller = controller

        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]

        register(center.playCommand) { controller, _ in
            controller.play()
            return .success
        }
        register(center.pauseCommand) { controller, _ in
            controller.pause()
            return .success
        }
        register(center.togglePlayPauseCommand) { controller, _ in
            controller.togglePlayPause()
            return .success
        }
        register(center.nextTrackCommand) { controller, _ in
            guard controller.hasNextEpisode else { return .noSuchContent }
            controller.nextEpisode()
            return .success
        }
        register(center.previousTrackCommand) { controller, _ in
            guard controller.hasPreviousEpisode else { return .noSuchContent }
            controller.previousEpisode()
            return .success
        }
        register(center.skipForwardCommand) { controller, event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            controller.seekRelative(by: interval)
            return .success
        }
        register(center.skipBackwardCommand) { controller, event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            controller.seekRelative(by: -interval)
            return .success
        }
        register(center.changePlaybackPositionCommand) { controller, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            controller.seek(to: event.positionTime)
            return .success
        }
        setNavigation(hasNext: controller.hasNextEpisode, hasPrevious: controller.hasPreviousEpisode)
    }

    private func register(
        _ command: MPRemoteCommand,
        _ handler: @escaping (PlayerController, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            guard let controller = self?.controller else { return .noActionableNowPlayingItem }
            return handler(controller, event)
        }
        registeredTargets.append((command, target))
    }

    private func detachCommands() {
        for (command, target) in registeredTargets {
            command.removeTarget(target)
        }
        registeredTargets.removeAll()
    }
}
