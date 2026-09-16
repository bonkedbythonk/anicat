// CoreSpotlight imports on tvOS but every type in it is marked
// unavailable there; the TV has no system search to index into.
#if !os(tvOS)
import CoreSpotlight
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The library and the watch history in the system search, so a title
/// typed into Spotlight opens its page. The earlier `SpotlightIndexer` was
/// deleted with the Tauri build and its rows are still being purged
/// (`purgeStaleSpotlightIndexOnce`); this one writes under its own domain.
extension AppModel {
    static let spotlightDomain = "titles"
    public static let spotlightActivityType = CSSearchableItemActionType

    /// One `CSSearchableItem` per known title, id in the unique identifier
    /// as the same `anicat://title/<id>` URL a notification tap carries,
    /// so the tap goes through `handleOpenURL` unchanged.
    @MainActor
    func refreshSpotlightIndex() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        var seen: Set<Int64> = []
        var items: [CSSearchableItem] = []
        func add(id: Int64, title: String, cover: URL?, isManga: Bool, subtitle: String?) {
            guard !title.isEmpty, seen.insert(id).inserted else { return }
            let attributes = CSSearchableItemAttributeSet(contentType: isManga ? .text : .video)
            attributes.title = title
            attributes.contentDescription = subtitle
            attributes.thumbnailURL = cover
            let link = DeepLink.title(id: id, isManga: isManga).url.absoluteString
            let item = CSSearchableItem(uniqueIdentifier: link, domainIdentifier: Self.spotlightDomain, attributeSet: attributes)
            item.expirationDate = Date().addingTimeInterval(30 * 24 * 3600)
            items.append(item)
        }
        for item in libraryItems { add(id: item.id, title: item.title, cover: item.coverImageURL, isManga: item.isManga, subtitle: item.isManga ? "Manga on Anicat" : "Anime on Anicat") }
        for item in watchingItems { add(id: item.id, title: item.title, cover: item.coverImageURL, isManga: false, subtitle: "Watching on Anicat") }
        for item in mangaReading { add(id: item.id, title: item.title, cover: item.coverImageURL, isManga: true, subtitle: "Reading on Anicat") }
        for entry in upNextItems { add(id: entry.id, title: entry.title, cover: entry.thumbnailURL, isManga: entry.unit == "CH", subtitle: "Up next: \(entry.unit) \(entry.nextEpisodeOrChapter)") }
        for (id, title) in knownTitles { add(id: id, title: title, cover: knownCovers[id], isManga: false, subtitle: "On Anicat") }
        guard !items.isEmpty else { return }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [Self.spotlightDomain]) { _ in
            index.indexSearchableItems(items) { error in
                if let error { AppLog.write("[spotlight] index failed: \(error.localizedDescription)") }
            }
        }
    }

    /// The identifier a Spotlight result hands back is the deep link.
    @MainActor
    public func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let url = URL(string: identifier) else { return }
        _ = handleOpenURL(url)
    }
}
#else
import Foundation

extension AppModel {
    func refreshSpotlightIndex() {}
    public func handleSpotlightActivity(_ activity: NSUserActivity) {}
}
#endif
