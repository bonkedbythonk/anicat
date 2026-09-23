#if os(iOS)
import AVFoundation

/// Keeps the app running in the background while a download is going, by
/// playing silence under the `audio` background mode the player already
/// declares.
///
/// The fallback for when iOS will not grant a `BGContinuedProcessingTask`:
/// on the owner's phone every request came back `BGTaskSchedulerErrorDomain`
/// 1 ("unavailable") with Background App Refresh on and Anicat enabled in it
/// (2026-09-23), and a suspended app downloads nothing. An app actually
/// playing audio is not suspended, and silence counts. Mixed with others,
/// so music the viewer has going keeps playing and nothing takes over the
/// lock screen. It costs some battery, which is why it has a switch
/// (`AppModel.keepsDownloadingInBackground`). The App Store would not take
/// it; this app is not distributed there.
@MainActor
final class DownloadKeepAlive {
    static let shared = DownloadKeepAlive()
    private var engine: AVAudioEngine?

    private init() {}

    var isRunning: Bool { engine != nil }

    func setRunning(_ running: Bool) {
        running ? start() : stop()
    }

    private func start() {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let source = Self.silence()
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: nil)
            try engine.start()
            self.engine = engine
            AppLog.write("[downloads] keeping the app awake with silence while a download runs in the background")
        } catch {
            AppLog.write("[downloads] could not keep the app awake: \(error.localizedDescription)")
        }
    }

    private func stop() {
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLog.write("[downloads] stopped keeping the app awake")
    }

    /// Zeros on the render thread. Built outside the main actor: the block
    /// runs on Core Audio's real-time thread and must not inherit isolation.
    private nonisolated static func silence() -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, _, audioBufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
    }
}
#endif
