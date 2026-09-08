import Foundation
import AnicatCoreKit

/// Reads and merges the one registry table worth copying between devices.
///
/// `resolved_releases` and nothing else. Watch progress and list state are
/// already synced by AniList, and the rest of the registry is unsafe to copy
/// blind: a track preference is stored by language plus subtitle title as a
/// tie-break for one release's mux, and the other device is routinely
/// playing a different release. A remembered release is the exception
/// because a stale one is self-healing -- `resolve` tries it under a bounded
/// budget and falls through to an ordinary search when it turns out dead.
@MainActor
enum RemoteSync {
    /// Reads `AppModel.shared` the way `RemoteHost` does rather than being
    /// handed an engine: both ends of this protocol run inside the one app,
    /// and threading an engine through the Network callbacks would mean
    /// keeping a second reference alive across a connection's lifetime.
    private static var engine: AnicatEngine? { AppModel.shared?.engine }

    static func export() -> [SyncRelease] {
        guard let engine else { return [] }
        guard let rows = try? engine.exportResolvedReleases() else { return [] }
        return rows.map {
            SyncRelease(
                catalog: catalogName($0.catalog),
                catalogId: $0.catalogId,
                episodeNumber: $0.episodeNumber,
                name: $0.name,
                magnet: $0.magnet,
                torrentUrl: $0.torrentUrl,
                assumeBatch: $0.assumeBatch,
                preferDub: $0.preferDub,
                resolvedAt: $0.resolvedAt
            )
        }
    }

    /// Merges what the other device sent and answers how many rows moved.
    /// Newest `resolvedAt` wins inside the engine, so this is safe in both
    /// directions and safe to repeat.
    @discardableResult
    static func merge(_ incoming: [SyncRelease]) -> UInt32 {
        guard let engine, !incoming.isEmpty else { return 0 }
        let mapped = incoming.compactMap { row -> FfiResolvedRelease? in
            // A catalog name this build cannot place is dropped rather than
            // guessed: the name says which id space `catalogId` is in.
            guard let catalog = catalog(named: row.catalog) else { return nil }
            return FfiResolvedRelease(
                catalog: catalog,
                catalogId: row.catalogId,
                episodeNumber: row.episodeNumber,
                name: row.name,
                magnet: row.magnet,
                torrentUrl: row.torrentUrl,
                assumeBatch: row.assumeBatch,
                preferDub: row.preferDub,
                resolvedAt: row.resolvedAt
            )
        }
        return (try? engine.importResolvedReleases(rows: mapped)) ?? 0
    }

    // The enum travels as the same string the database column holds, not as
    // its ordinal: a reordered enum must not silently repoint rows at
    // another catalog, which is the rule `db::Catalog` is written to.
    private static func catalogName(_ catalog: FfiCatalog) -> String {
        switch catalog {
        case .anilist: return "anilist"
        case .tmdbMovie: return "tmdb_movie"
        case .tmdbTv: return "tmdb_tv"
        case .mangaDex: return "mangadex"
        }
    }

    private static func catalog(named name: String) -> FfiCatalog? {
        switch name {
        case "anilist": return .anilist
        case "tmdb_movie": return .tmdbMovie
        case "tmdb_tv": return .tmdbTv
        case "mangadex": return .mangaDex
        default: return nil
        }
    }
}
