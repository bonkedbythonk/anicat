import Foundation
import CoreSpotlight
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Publishes the viewer's own titles to Spotlight, so typing a show's name
/// into the system search field finds the entry in Anicat rather than only
/// whatever the web knows about it.
///
/// Only the viewer's titles are indexed — the library, what they are
/// watching, and anything the history log has a name for. A trending shelf is
/// a catalog listing that changes every day; indexing it would put thousands
/// of rows nobody has any relationship with into the system index and make
/// every Anicat hit meaningless.
enum SpotlightIndexer {
    /// The `CSSearchableItem` domain, so one `deleteSearchableItems` call can
    /// drop everything this indexer ever wrote without touching Handoff's own
    /// `NSUserActivity` entries.
    static let domainIdentifier = "library"

    /// Prefix of the unique id. It doubles as the parse key on the way back:
    /// a Spotlight hit hands the app the id string and nothing else.
    static let identifierPrefix = "anilist:"

    struct Entry: Sendable, Hashable {
        let id: Int64
        let title: String
        let coverURL: URL?
        let isManga: Bool
    }

    /// Poster edge for the indexed thumbnail. Spotlight scales what it is
    /// given; a full 460px AniList cover per row is a few hundred KB of
    /// `thumbnailData` written into the system index for no visible gain.
    private static let thumbnailPixelSize: CGFloat = 180

    /// How many entries get a thumbnail. Every miss past the decode cache is
    /// a network fetch, and a several-hundred-title library would otherwise
    /// pull its entire cover set on a background index pass. The rows past
    /// this cap are still indexed, just without artwork.
    private static let thumbnailBudget = 120

    static func deepLink(forIdentifier identifier: String) -> DeepLink? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let rest = identifier.dropFirst(identifierPrefix.count)
        guard let id = Int64(rest) else { return nil }
        // The id alone does not say whether the entry is manga, so the link
        // opens the anime detail page. `openDetail` fetches the real media
        // and lays out whatever it turns out to be.
        return .title(id: id, isManga: false)
    }

    /// Replaces the whole `library` domain with `entries`. A replace rather
    /// than an add: a title removed from the viewer's list has to leave the
    /// index too, and there is no per-row delete signal to hang that on.
    ///
    /// Sequential by design — see `thumbnailBudget`.
    static func reindex(_ entries: [Entry]) async {
        // Empty means "the lists have not loaded yet", which is what the
        // launch pass sees — wiping the index on it would leave Spotlight
        // with nothing for as long as AniList takes to answer. Signing out
        // therefore leaves stale rows behind until the next list load
        // replaces them, which is the cheaper of the two wrong answers.
        guard !entries.isEmpty else { return }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()

        var items: [CSSearchableItem] = []
        items.reserveCapacity(entries.count)
        var thumbnailsFetched = 0

        for entry in entries {
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = entry.title
            attributes.contentDescription = entry.isManga ? "Manga in your Anicat library" : "Anime in your Anicat library"
            attributes.keywords = [entry.isManga ? "manga" : "anime", "anicat"]
            if let coverURL = entry.coverURL {
                if let cached = ImageDecodeCache.shared.cachedImage(for: coverURL, maxPixelSize: thumbnailPixelSize) {
                    attributes.thumbnailData = pngData(from: cached)
                } else if thumbnailsFetched < thumbnailBudget {
                    thumbnailsFetched += 1
                    if let fetched = await ImageDecodeCache.shared.image(
                        for: coverURL,
                        fit: .maxPixelSize(thumbnailPixelSize),
                        priority: .background
                    ) {
                        attributes.thumbnailData = pngData(from: fetched)
                    }
                }
            }
            items.append(
                CSSearchableItem(
                    uniqueIdentifier: "\(identifierPrefix)\(entry.id)",
                    domainIdentifier: domainIdentifier,
                    attributeSet: attributes
                )
            )
            if Task.isCancelled { return }
        }

        try? await index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
        guard !items.isEmpty else { return }
        try? await index.indexSearchableItems(items)
    }

    /// `CGImage` is what the decode cache stores, and `thumbnailData` wants
    /// bytes. PNG rather than JPEG because AniList covers arrive with no
    /// alpha but the downsample can produce some, and a JPEG encoder silently
    /// composites it onto black.
    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
