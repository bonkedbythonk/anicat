// `ANICAT_XCODE` is set only by the xcodegen app target. The SwiftPM iOS
// library build (`swift build --product AnicatUI --triple ...-ios...`, what
// CI runs) compiles this executable target too, without `Shared/`, and
// `os(iOS)` alone was not enough to keep it out.
#if os(iOS) && ANICAT_XCODE
import ActivityKit
import SwiftUI
import WidgetKit
import AnicatUI

/// The phone-only system surfaces that need the model and the shared
/// widget types at once: the widget snapshot and the Live Activities.
///
/// In the app target rather than in `AnicatUI` because `WidgetSnapshot`
/// and the `ActivityAttributes` are compiled into the widget extension
/// too, and the extension cannot depend on the UI package. A zero-sized
/// view, like `SystemIntegrationObserver`, so the observation re-evaluates
/// this body and not the scene's.
struct IOSIntegrations: View {
    let model: AppModel
    private let remote = RemoteClient.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: model.systemIntegrationSignature, initial: true) { _, _ in
                WidgetSnapshotWriter.write(from: model)
            }
            .onChange(of: model.scheduleItems.count) { _, _ in
                WidgetSnapshotWriter.write(from: model)
            }
            .onChange(of: model.downloadSignature, initial: true) { _, _ in
                LiveActivityBridge.shared.syncDownloads(model.libraryDownloads)
            }
            .onChange(of: remoteSignature, initial: true) { _, _ in
                LiveActivityBridge.shared.syncRemote(
                    state: remote.state,
                    connected: remote.status == .connected,
                    macName: remote.hostName ?? BonjourDiscovery.shared.discoveredMacNode?.name ?? "Mac")
            }
    }

    /// The remote state projected to what the activity shows, so a
    /// per-second `currentTime` tick does not re-request anything.
    private var remoteSignature: String {
        let s = remote.state
        return "\(remote.status == .connected)|\(s.hasPlayback)|\(s.isPlaying)|\(s.title)|\(s.episodeNumber)|\(Int(s.currentTime / 15))|\(Int(s.duration))"
    }
}

/// Writes what the three widgets draw. Nothing happens without the App
/// Group container: a build signed without the entitlement (a personal
/// team, or CI) resolves no container, and the widgets show their
/// placeholders rather than the app failing.
enum WidgetSnapshotWriter {
    @MainActor
    static func write(from model: AppModel) {
        guard AnicatWidgetShared.snapshotURL != nil else { return }
        let upNext = model.upNextItems.prefix(6).map {
            WidgetSnapshot.UpNextEntry(
                id: $0.id, title: $0.title, episode: $0.nextEpisodeOrChapter,
                coverURL: $0.thumbnailURL?.absoluteString, isNew: $0.hasNewEpisode)
        }
        let airing = model.scheduleItems.prefix(40).map {
            WidgetSnapshot.AiringEntry(
                id: $0.id, title: $0.title, episode: $0.episodeNumber, airingAt: $0.airingAt,
                coverURL: $0.coverImageURL?.absoluteString, isWatching: $0.isWatching)
        }
        let reading = model.mangaReading.filter { ($0.progress ?? 0) > 0 }.prefix(6).map {
            WidgetSnapshot.ReadingEntry(
                id: $0.id, title: $0.title, nextChapter: ($0.progress ?? 0) + 1,
                coverURL: $0.coverImageURL?.absoluteString)
        }
        let snapshot = WidgetSnapshot(upNext: Array(upNext), airing: Array(airing), reading: Array(reading))
        do {
            try snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            AppLog.write("[widgets] snapshot write failed: \(error.localizedDescription)")
        }
    }
}

// ActivityKit's handle is not marked Sendable, and every `update`/`end` is
// an async call off the main actor. It is ActivityKit's own thread-safe
// object; the content is a value whose state is `Sendable` in Shared.
extension Activity: @unchecked @retroactive Sendable {}

/// One activity per download in flight and one for the Mac's playback.
/// `Activity.request` throws when the plist lacks
/// `NSSupportsLiveActivities` or the user has turned activities off; both
/// are logged and otherwise ignored.
@MainActor
final class LiveActivityBridge {
    static let shared = LiveActivityBridge()
    private var downloads: [String: Activity<DownloadActivityAttributes>] = [:]
    private var remote: Activity<RemoteActivityAttributes>?

    private init() {}

    func syncDownloads(_ rows: [AppModel.LibraryDownload]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        var live: Set<String> = []
        for row in rows {
            switch row.state {
            case .downloading(let percent):
                live.insert(row.id)
                let state = DownloadActivityAttributes.ContentState(percent: percent, status: "Downloading")
                if let activity = downloads[row.id] {
                    Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
                } else {
                    let attributes = DownloadActivityAttributes(
                        title: row.title, episode: row.episode, isFilm: row.catalog == .tmdbMovie)
                    do {
                        downloads[row.id] = try Activity.request(
                            attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
                    } catch {
                        AppLog.write("[activity] download request failed: \(error.localizedDescription)")
                    }
                }
            case .done:
                if let activity = downloads.removeValue(forKey: row.id) {
                    let state = DownloadActivityAttributes.ContentState(percent: 100, status: "Downloaded")
                    Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60))) }
                }
            case .failed(let message):
                if let activity = downloads.removeValue(forKey: row.id) {
                    let state = DownloadActivityAttributes.ContentState(percent: 0, status: message)
                    Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60))) }
                }
            case .notStarted:
                break
            }
        }
        // Rows that vanished (removed from the Downloads page mid-flight).
        for (id, activity) in downloads where !live.contains(id) {
            downloads[id] = nil
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func syncRemote(state: RemoteState, connected: Bool, macName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let wanted = connected && state.hasPlayback
        let content = RemoteActivityAttributes.ContentState(
            title: state.title, episode: state.episodeNumber, isPlaying: state.isPlaying,
            currentTime: state.currentTime, duration: state.duration)
        if wanted {
            if let remote {
                Task { await remote.update(ActivityContent(state: content, staleDate: nil)) }
            } else {
                do {
                    remote = try Activity.request(
                        attributes: RemoteActivityAttributes(macName: macName),
                        content: ActivityContent(state: content, staleDate: nil))
                } catch {
                    AppLog.write("[activity] remote request failed: \(error.localizedDescription)")
                }
            }
        } else if let activity = remote {
            remote = nil
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
#endif
