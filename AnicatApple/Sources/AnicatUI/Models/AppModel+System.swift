import Foundation
import SwiftUI
import CoreSpotlight
#if canImport(AppKit)
import AppKit
#endif

/// The macOS/iOS integration surfaces, joined to the model: the `anicat://`
/// scheme, App Intents, Spotlight, notifications and the dock badge.
///
/// Every one of them arrives from outside the view tree, and every one of
/// them ends in a `DeepLink` handled by `handleDeepLink` — so there is one
/// place that knows how to reach a screen, rather than five.
extension AppModel {
    /// Publishes this instance for the callers that cannot be handed it: an
    /// App Intent is built by the Shortcuts runtime, and the notification
    /// delegate by the system. Called from `AnicatApp.init`.
    public func registerAsShared() {
        AppModel.shared = self
        SystemNotifications.shared.activate()
    }

    // MARK: - Deep links

    /// Entry point for `.onOpenURL`. Answers whether the URL was ours, so a
    /// caller can tell "handled" from "not an Anicat link".
    @discardableResult
    @MainActor
    public func handleOpenURL(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        handleDeepLink(link)
        return true
    }

    /// Entry point for a Spotlight result. `CSSearchableItemActionType`
    /// activities carry the unique id and nothing else, which is why
    /// `SpotlightIndexer` encodes the catalog id into it.
    @discardableResult
    @MainActor
    public func handleSpotlightActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let link = SpotlightIndexer.deepLink(forIdentifier: identifier) else { return false }
        handleDeepLink(link)
        return true
    }

    @MainActor
    public func handleDeepLink(_ link: DeepLink) {
        // A notification tap or a Spotlight hit can launch the app, and it
        // arrives long before `initialize()` has an engine. `openDetail` and
        // `playFromShelf` both bail on a nil engine without saying so, so
        // without this the app opened and then sat on the home screen.
        guard isInitialized else {
            pendingDeepLink = link
            return
        }

        switch link {
        case .title(let id, let isManga):
            Task { await openDetail(id: id, isManga: isManga) }
        case .play(let id, let episode):
            playFromShelf(
                model: self,
                catalogId: id,
                episode: episode,
                // A link can name a title no list has ever mentioned, and
                // `playFromShelf` wants a non-optional one. Not `""`: both
                // fallback chains this string feeds — `loadDetail`'s
                // `title ?? knownTitles[id] ?? "Loading..."` for the hero and
                // `resolveAndPlay`'s `?? "Anime"` for the player and Discord
                // — are nil-coalescing, so an empty string is not a missing
                // title to either of them and both render blank. This is
                // `resolveAndPlay`'s own floor, spelled out.
                title: knownTitles[id] ?? "Anime",
                coverURL: knownCovers[id]
            )
        case .search(let query):
            navigate(to: .search)
            searchQuery = query
            // No `search()` call here: `SearchView` commits its own bound
            // text through a `.task(id:)` debounce, and running the query
            // from both sides fires the same AniList request twice.
        case .section(let section):
            navigate(to: section)
        }
    }

    /// Runs whatever arrived before the engine was up. Called once from the
    /// app's launch task, straight after `initialize()`.
    @MainActor
    public func drainPendingDeepLink() {
        guard let link = pendingDeepLink else { return }
        pendingDeepLink = nil
        handleDeepLink(link)
    }

    // MARK: - Spotlight

    /// The viewer's own titles, deduplicated by id. Sourced from the library,
    /// the watching list and whatever else has left a name in `knownTitles` —
    /// which is where the history log's titles end up.
    var spotlightEntries: [SpotlightIndexer.Entry] {
        var seen = Set<Int64>()
        var entries: [SpotlightIndexer.Entry] = []
        for item in libraryItems + watchingItems + mangaReading + novelReading where seen.insert(item.id).inserted {
            entries.append(
                SpotlightIndexer.Entry(
                    id: item.id,
                    title: item.title,
                    coverURL: item.coverImageURL,
                    isManga: item.isManga
                )
            )
        }
        for (id, title) in knownTitles where seen.insert(id).inserted {
            entries.append(
                SpotlightIndexer.Entry(id: id, title: title, coverURL: knownCovers[id], isManga: false)
            )
        }
        return entries
    }

    /// What `SystemIntegrationObserver` compares to decide the lists have
    /// moved. Counts rather than every id, plus the library's own filter,
    /// because this is recomputed on every change to any observed property
    /// and building a few hundred ids into a string each time is the kind of
    /// per-frame work the FPS HUD was added to catch. The Up Next entries are
    /// spelled out in full because the notification edge is defined on
    /// exactly those fields.
    public var systemIntegrationSignature: String {
        let queue = upNextItems
            .map { "\($0.id):\($0.nextEpisodeOrChapter):\($0.hasNewEpisode ? 1 : 0)" }
            .joined(separator: ",")
        return "\(libraryItems.count)/\(libraryStatus)/\(libraryType)/\(watchingItems.count)"
            + "/\(mangaReading.count)/\(novelReading.count)/\(knownTitles.count)|\(queue)"
    }

    /// `LibraryDownload` is not `Equatable`, so the download edge is watched
    /// through this projection instead of the array itself.
    public var downloadSignature: String {
        libraryDownloads.map { "\($0.id):\($0.state)" }.joined(separator: ",")
    }

    /// Re-indexes Spotlight, checks for episodes to announce and restamps the
    /// dock badge. Called after the library lists change; safe to call as
    /// often as they do.
    @MainActor
    public func refreshSystemIntegrations() {
        updateDockBadge()
        notifyAboutNewEpisodes()

        let entries = spotlightEntries
        spotlightIndexTask?.cancel()
        spotlightIndexTask = Task.detached(priority: .background) {
            // `refreshAll` writes five list properties in a row and each one
            // lands here; the sleep collapses those into one index pass over
            // the whole library instead of five.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await SpotlightIndexer.reindex(entries)
        }
    }

    // MARK: - Notifications

    /// Announces titles whose "new episode" flag has just turned on.
    @MainActor
    func notifyAboutNewEpisodes() {
        // An empty queue is "nothing loaded yet", not "nothing airing": the
        // observer fires once at launch before either the cache or AniList
        // has filled the list, and seeding from that empty state would make
        // every backlogged show on the watching list look newly aired the
        // moment the real list arrived.
        guard !upNextItems.isEmpty else { return }
        let current = Set(
            upNextItems
                .filter { $0.hasNewEpisode && $0.unit != "CH" }
                .map { "\($0.id):\($0.nextEpisodeOrChapter)" }
        )
        // The first look of a session only records. Everything already
        // backlogged on the watching list has a new episode by this
        // definition, and announcing all of it at launch is a notification
        // storm, not news.
        guard let previous = lastKnownNewEpisodeKeys else {
            lastKnownNewEpisodeKeys = current
            return
        }
        lastKnownNewEpisodeKeys = current
        let appeared = current.subtracting(previous)
        guard !appeared.isEmpty else { return }

        for entry in upNextItems where appeared.contains("\(entry.id):\(entry.nextEpisodeOrChapter)") {
            let id = entry.id
            let episode = entry.nextEpisodeOrChapter
            let title = entry.title
            let cover = knownCovers[id] ?? entry.thumbnailURL
            Task.detached(priority: .utility) {
                await SystemNotifications.shared.notifyNewEpisode(
                    catalogId: id,
                    title: title,
                    episode: episode,
                    coverURL: cover
                )
            }
        }
    }

    /// Announces downloads that have just reached `.done`. Driven from the
    /// app's own `.onChange` on `libraryDownloads`, because that property is
    /// written by the download path and cannot carry a `didSet` of ours.
    @MainActor
    public func handleDownloadsChanged() {
        var completed = Set<String>()
        for download in libraryDownloads {
            if case .done = download.state { completed.insert(download.id) }
        }
        // Same seed-without-announcing rule as the episode check: the
        // downloads list is rebuilt at launch with everything already
        // finished still in it.
        guard let previous = lastKnownCompletedDownloadIds else {
            lastKnownCompletedDownloadIds = completed
            return
        }
        lastKnownCompletedDownloadIds = completed
        let finished = completed.subtracting(previous)
        guard !finished.isEmpty else { return }

        for download in libraryDownloads where finished.contains(download.id) {
            let id = download.catalogId
            let episode = download.episode
            let title = download.title
            let cover = download.coverURL ?? knownCovers[id]
            Task.detached(priority: .utility) {
                await SystemNotifications.shared.notifyDownloadFinished(
                    catalogId: id,
                    title: title,
                    episode: episode,
                    coverURL: cover
                )
            }
        }
    }

    // MARK: - Dock badge

    /// Titles on the watching list with an aired episode the viewer has not
    /// reached. The same count Up Next's own "2 new episodes" subtitle shows,
    /// so the two can never disagree.
    public var newEpisodeBadgeCount: Int {
        upNextItems.filter { $0.hasNewEpisode && $0.unit != "CH" }.count
    }

    /// Stamps the dock tile. Looking at Up Next *is* reading the badge, so it
    /// clears while that section is open rather than needing its own
    /// "dismissed" flag that a later refresh would have to remember to honour.
    @MainActor
    public func updateDockBadge() {
        #if os(macOS)
        // No badge since 2026-09-07 at the owner's request ("unneeded"):
        // the count still lives in Up Next's subtitle. Clearing rather than
        // returning, so a badge left by an earlier build goes away.
        NSApp?.dockTile.badgeLabel = nil
        #endif
    }
}
