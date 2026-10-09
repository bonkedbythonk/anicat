import Foundation
import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The macOS/iOS integration surfaces, joined to the model: the `anicat://`
/// scheme, App Intents and the dock badge.
///
/// Every one of them arrives from outside the view tree, and every one of
/// them ends in a `DeepLink` handled by `handleDeepLink` — so there is one
/// place that knows how to reach a screen, rather than five.
extension AppModel {
    /// Publishes this instance for the callers that cannot be handed it: an
    /// App Intent is built by the Shortcuts runtime. Called from
    /// `AnicatApp.init`.
    public func registerAsShared() {
        AppModel.shared = self
    }

    /// Keeps the engine's caches out of iCloud and Time Machine.
    ///
    /// The data dir is Application Support, which is backed up in full, and
    /// `torrent-streams/` under it is capped at 3 GiB of video that the
    /// swarm hands back on demand. On a phone that is every iCloud backup
    /// carrying three gigabytes of episodes already watched, and Apple's
    /// review guidance names re-downloadable content as exactly what the
    /// exclusion flag is for. The registry stays: watch history and local
    /// library are the one thing here that cannot be fetched again.
    ///
    /// After engine construction, which creates the cache file. The three
    /// directories are created here rather than waited for: the engine
    /// makes them lazily on the first stream or download, and a flag set
    /// only on the next launch leaves that first session's files in the
    /// backup (seen on the simulator: `offline-manga` unflagged after a
    /// launch that never opened a chapter).
    static func excludeCachesFromBackup(dataDir: URL) {
        let fm = FileManager.default
        let directories = ["torrent-streams", "offline-manga", "offline-novels"]
            .map { dataDir.appendingPathComponent($0, isDirectory: true) }
        for dir in directories {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let candidates = directories + [dataDir.appendingPathComponent("catalog-cache.sqlite")]
        for url in candidates where fm.fileExists(atPath: url.path) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            do {
                try mutable.setResourceValues(values)
            } catch {
                AppLog.write("[backup] could not exclude \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
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
        // No Spotlight on tvOS, so nothing the indexer could have written.
        // `os`, not `canImport`: the framework is importable there and its
        // index class is not.
        #if !os(tvOS)
        Task.detached(priority: .background) {
            guard CSSearchableIndex.isIndexingAvailable() else { return }
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["library"])
        }
        #endif
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
        // A deep link can launch the app, and it arrives long before
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
        case .remote:
            #if os(iOS)
            // A request, not a presentation: the sheet belongs to
            // `RootTabView`, which is also the only place that knows whether
            // a Mac is in range to show it for.
            wantsRemoteSheet = true
            #endif
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
    /// spelled out in full because the Spotlight subtitles carry their
    /// episode numbers.
    public var systemIntegrationSignature: String {
        let queue = upNextItems
            .map { "\($0.id):\($0.nextEpisodeOrChapter)" }
            .joined(separator: ",")
        return "\(libraryItems.count)/\(libraryStatus)/\(libraryType)/\(watchingItems.count)"
            + "/\(mangaReading.count)/\(novelReading.count)/\(knownTitles.count)|\(queue)"
    }

    /// `LibraryDownload` is not `Equatable`, so changes are watched through
    /// this projection instead of the array itself.
    public var downloadSignature: String {
        libraryDownloads.map { "\($0.id):\($0.state)" }.joined(separator: ",")
    }

    /// Restamps the dock badge and the Spotlight index. Called after the
    /// library lists change; safe to call as often as they do.
    @MainActor
    public func refreshSystemIntegrations() {
        updateDockBadge()
        refreshSpotlightIndex()
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
