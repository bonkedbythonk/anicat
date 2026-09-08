import Foundation
import SwiftUI
import CoreSpotlight
#if canImport(AppKit)
import AppKit
#endif

/// The macOS/iOS integration surfaces, joined to the model: the `anicat://`
/// scheme, App Intents, notifications and the dock badge.
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

    /// One-shot cleanup for rows the now-deleted `SpotlightIndexer` wrote
    /// under its `"library"` domain before it was removed — deleting that
    /// file took its own `clear()` call with it, so without this those show
    /// titles stay searchable forever with no code path left that knows
    /// about them. `UserDefaults` guards it to one run per install; safe to
    /// delete this method entirely once every machine that ever ran the
    /// indexer has launched a build past this one.
    @MainActor
    public func purgeStaleSpotlightIndexOnce() {
        let key = "anicat_spotlight_purged_2026_09_08"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task.detached(priority: .background) {
            guard CSSearchableIndex.isIndexingAvailable() else { return }
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["library"])
        }
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

    @MainActor
    public func handleDeepLink(_ link: DeepLink) {
        // A notification tap can launch the app, and it arrives long before
        // `initialize()` has an engine. `openDetail` and
        // `playFromShelf` both bail on a nil engine without saying so, so
        // without this the app opened and then sat on the home screen.
        guard isInitialized else {
            pendingDeepLink = link
            return
        }

        switch link {
        case .title(let id, let isManga, let catalog):
            if catalog == .anilist {
                Task { await openDetail(id: id, isManga: isManga) }
            } else {
                Task { await openCinemaDetail(catalog: catalog, id: id) }
            }
        case .play(let id, let episode, let catalog):
            guard catalog == .anilist else {
                // A film's page first, then the stream over it -- the same
                // shape as the cinema shelves' own Play, and the only route
                // that resolves against TMDB rather than against whatever
                // anime shares the number.
                Task {
                    await openCinemaDetail(catalog: catalog, id: id)
                    await playCinemaEpisode(episode)
                }
                return
            }
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

    /// Checks for episodes to announce and restamps the dock badge. Called
    /// after the library lists change; safe to call as often as they do.
    @MainActor
    public func refreshSystemIntegrations() {
        updateDockBadge()
        notifyAboutNewEpisodes()
    }

    // MARK: - Notifications

    /// Announces titles whose "new episode" -- or new chapter -- flag has
    /// just turned on.
    @MainActor
    func notifyAboutNewEpisodes() {
        // An empty queue is "nothing loaded yet", not "nothing airing": the
        // observer fires once at launch before either the cache or AniList
        // has filled the list, and seeding from that empty state would make
        // every backlogged show on the watching list look newly aired the
        // moment the real list arrived.
        guard !upNextItems.isEmpty else { return }
        // Chapters included: they were filtered out here while the queue
        // has carried them all along, so a manga that updated said nothing.
        // The key carries the unit for the same reason the notification does
        // -- chapter 5 and episode 5 of one title are different news.
        let current = Set(
            upNextItems
                .filter(\.hasNewEpisode)
                .map { "\($0.unit):\($0.id):\($0.nextEpisodeOrChapter)" }
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

        for entry in upNextItems
        where appeared.contains("\(entry.unit):\(entry.id):\(entry.nextEpisodeOrChapter)") {
            let id = entry.id
            let episode = entry.nextEpisodeOrChapter
            let title = entry.title
            let cover = knownCovers[id] ?? entry.thumbnailURL
            let unit: SystemNotifications.ReleaseUnit = entry.unit == "CH" ? .chapter : .episode
            Task.detached(priority: .utility) {
                await SystemNotifications.shared.notifyNewEpisode(
                    catalogId: id,
                    title: title,
                    episode: episode,
                    coverURL: cover,
                    unit: unit
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
            let catalog = download.catalog
            let cover = download.coverURL ?? registryCover(catalog: catalog.ffi, id: id)
            Task.detached(priority: .utility) {
                await SystemNotifications.shared.notifyDownloadFinished(
                    catalog: catalog,
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
