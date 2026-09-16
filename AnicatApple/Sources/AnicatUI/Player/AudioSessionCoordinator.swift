#if os(iOS)
import AVFoundation
import UIKit

/// The iOS audio session and the two things the phone does to a stream that
/// the Mac never has to: keep the sound going with the screen off, and
/// give the picture up while it does.
///
/// `UIBackgroundModes: audio` in the plist is a permission, not a behaviour.
/// Without a `.playback` category set and the session activated, iOS treats
/// the app like any other and the sound stops the moment the phone is
/// pocketed -- which is exactly what the plist comment promised the key
/// prevented. This is the other half.
///
/// The video half is the MPVKit demo's own trick: `vid=no` on the way to the
/// background, `vid=auto` on the way back. mpv's vo keeps rendering to the
/// `CAMetalLayer` from its own thread with no idea the app was suspended,
/// and a Metal submission from a backgrounded process is a termination, not
/// an error.
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private weak var controller: PlayerController?
    private var isActive = false
    /// Whether the interruption paused a playing episode, as opposed to
    /// arriving on one that was already paused. Only the former resumes:
    /// a phone call over a paused frame should hang up onto a paused frame.
    private var resumeAfterInterruption = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Called on every playback-session sync while a stream is open; the
    /// `isActive` guard makes the repeats free. `controller` is re-pinned
    /// every time so a new player object after a relaunch is the one the
    /// callbacks reach.
    func begin(controller: PlayerController) {
        self.controller = controller
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.moviePlayback` over `.default`: it tells the route that
            // this is a film, which is what lets AirPlay audio and the
            // lock-screen scrubber treat it as one long track.
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            AppLog.write("[audio] session activate failed: \(error.localizedDescription)")
        }
        isActive = true
        installObservers()
    }

    /// The stream is gone. `notifyOthersOnDeactivation` is what lets the
    /// music app the viewer had going before resume by itself.
    func end() {
        guard isActive else { return }
        isActive = false
        resumeAfterInterruption = false
        removeObservers()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLog.write("[audio] session deactivate failed: \(error.localizedDescription)")
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers = [
            // The raw values are pulled out before crossing into the main
            // actor: `Notification` is not Sendable and Swift 6 refuses to
            // carry it into `assumeIsolated`.
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                MainActor.assumeIsolated { self?.handleInterruption(typeRaw: type, optionsRaw: options) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                MainActor.assumeIsolated { self?.handleRouteChange(reasonRaw: reason) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.onSetVideoEnabled?(false) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.onSetVideoEnabled?(true) }
            },
        ]
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// A phone call, Siri, an alarm. mpv does not hear these: it keeps
    /// pushing samples into an audio unit the system has muted, so without
    /// this the episode ran on silently under the call and the viewer came
    /// back two minutes further in.
    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
              let controller else { return }
        switch type {
        case .began:
            resumeAfterInterruption = controller.isPlaying
            if controller.isPlaying { controller.pause() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume), resumeAfterInterruption {
                controller.play()
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    /// Headphones pulled out. The system's convention is to pause rather
    /// than switch to the speaker at whatever volume the headphones were at.
    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
              reason == .oldDeviceUnavailable else { return }
        controller?.pause()
    }
}
#endif
