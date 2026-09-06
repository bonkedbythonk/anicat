import Foundation
import SwiftUI

/// The macOS/iOS integration surfaces, joined to the model. Every one of them
/// arrives from outside the view tree, and every one of them ends in a
/// `DeepLink` handled by `handleDeepLink` — so there is one place that knows
/// how to reach a screen, rather than one per surface.
extension AppModel {
    /// Publishes this instance for the callers that cannot be handed it: an
    /// App Intent is built by the Shortcuts runtime, and the notification
    /// delegate by the system. Called from `AnicatApp.init`.
    public func registerAsShared() {
        AppModel.shared = self
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
        // A link can launch the app, and it arrives long before
        // `initialize()` has an engine. `openDetail` and `playFromShelf` both
        // bail on a nil engine without saying so, so without this the app
        // opened and then sat on the home screen.
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
}
