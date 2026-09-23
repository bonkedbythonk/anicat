#if os(iOS)
import BackgroundTasks
import Foundation

/// Keeps a download running after the app leaves the screen.
///
/// iOS suspends a backgrounded app within seconds, and a torrent is not
/// something a background `URLSession` can carry, so a download used to stop
/// the moment the phone was locked while its Live Activity stayed up showing
/// the last percent (owner, 2026-09-23). A `BGContinuedProcessingTask`
/// (iOS 26) is the system's answer for work the user started: the app keeps
/// running for as long as the task reports progress, and the system draws
/// the progress itself.
///
/// One task per download, each with its own identifier under
/// `com.anicat.ios.download.*` (the pattern `project.yml` declares), its
/// handler registered immediately before the submit: a single wildcard
/// handler is refused by the scheduler (Apple DTS, forums thread 799126).
/// Anything that fails -- an older iOS, a refused registration, a submit
/// error -- leaves the download as it was, foreground only, and says so in
/// the log.
@MainActor
public final class DownloadBackgroundTasks {
    public static let shared = DownloadBackgroundTasks()
    static let identifierPrefix = "com.anicat.ios.download."

    /// Keyed by download key; `BGContinuedProcessingTask` is iOS 26 only,
    /// so the value is kept untyped and cast where it is used.
    private var running: [String: AnyObject] = [:]
    /// Submitted, not yet started by the scheduler.
    private var submitted: Set<String> = []
    /// The latest percent per download, for a task that starts after the
    /// download already has some.
    private var lastPercent: [String: Double] = [:]

    private init() {}

    /// Whether the system is keeping the app alive for a download right now,
    /// which makes `DownloadKeepAlive` unnecessary.
    public var hasRunningTask: Bool { !running.isEmpty }

    public static func key(catalogId: Int64, episode: Int) -> String {
        "\(catalogId)_\(episode)"
    }

    /// Whether a task for this download is submitted or running. Not used to
    /// hide the app's own download Live Activity: that is the one in the
    /// Dynamic Island, and hiding it while a task sat queued left the owner
    /// with no progress anywhere (2026-09-23).
    public func isTracked(_ key: String) -> Bool {
        running[key] != nil || submitted.contains(key)
    }

    /// Asks the system to keep this download alive in the background. Called
    /// on the tap that started it, while the app is in the foreground, which
    /// is when a request may be made.
    public func begin(key: String, title: String, subtitle: String) {
        guard #available(iOS 26.0, *) else { return }
        guard !isTracked(key) else { return }
        let identifier = Self.identifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                AppLog.write("[downloads] background task launched: \(task.identifier)")
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.started(task, key: key)
            }
        }
        guard registered else {
            AppLog.write("[downloads] background task not registered for \(identifier): not in BGTaskSchedulerPermittedIdentifiers?")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Fail, not queue: a queued request was accepted on the owner's phone
        // and never started, with nothing logged, and the download stopped
        // when the app left the screen. A refusal now says so at the tap.
        request.strategy = .fail
        // Marked before the submit: a task the system starts at once must find
        // itself expected in `started`, or it is completed on the spot.
        submitted.insert(key)
        if #available(iOS 27.0, *) {
            // The completion form, not `submit(_:)`: on the owner's phone
            // `submit` returned without an error and the task never started.
            // Apple deprecated it because the scheduler daemon's refusals
            // (an app it does not see as foreground, among them) could not
            // reach its return value; this handler gets them. Off the main
            // thread, as its documentation asks.
            nonisolated(unsafe) let request = request
            DispatchQueue.global(qos: .userInitiated).async {
                BGTaskScheduler.shared.submitTaskRequest(request) { error in
                    Task { @MainActor in
                        if let error {
                            self.submitted.remove(key)
                            AppLog.write("[downloads] background task refused for \(title): \(error.localizedDescription)")
                        } else {
                            AppLog.write("[downloads] background task accepted for \(title)")
                        }
                    }
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(request)
                AppLog.write("[downloads] background task submitted for \(title)")
            } catch {
                submitted.remove(key)
                AppLog.write("[downloads] background task refused for \(title): \(error.localizedDescription)")
            }
        }
    }

    @available(iOS 26.0, *)
    private func started(_ task: BGContinuedProcessingTask, key: String) {
        // A queued task can start after its download has already ended, and
        // `finish` found nothing to complete then; it is done now.
        guard submitted.remove(key) != nil, running[key] == nil else {
            task.setTaskCompleted(success: true)
            return
        }
        running[key] = task
        // Fine-grained units: a slow swarm moves a whole percent a minute or
        // less, and a task whose progress looks stalled gets expired.
        task.progress.totalUnitCount = 100_000
        task.progress.completedUnitCount = Int64((lastPercent[key] ?? 0) * 1000)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                AppLog.write("[downloads] background task expired for \(key)")
                self?.finish(key: key, success: false)
            }
        }
        AppLog.write("[downloads] background task started for \(key)")
    }

    public func update(key: String, percent: Double) {
        lastPercent[key] = percent
        guard #available(iOS 26.0, *), let task = running[key] as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(min(max(percent, 0), 100) * 1000)
        task.updateTitle(task.title, subtitle: "\(Int(percent))% downloaded")
    }

    /// Ends the task exactly once. The expiration handler and the download's
    /// own end can both arrive; whichever is first takes the task out of
    /// `running`, and the second finds nothing to complete.
    public func finish(key: String, success: Bool) {
        submitted.remove(key)
        lastPercent[key] = nil
        guard #available(iOS 26.0, *), let task = running.removeValue(forKey: key) as? BGContinuedProcessingTask else { return }
        task.setTaskCompleted(success: success)
        AppLog.write("[downloads] background task \(success ? "completed" : "ended unfinished") for \(key)")
    }
}
#endif
