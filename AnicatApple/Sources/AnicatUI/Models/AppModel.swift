import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

@Observable
public final class AppModel: @unchecked Sendable {
    public var engine: AnicatEngine?
    public var isInitialized = false
    public var isLoading = false
    public var errorMessage: String?

    // Active Navigation
    public var selectedMediaDetails: HeroBanner.Details?
    public var selectedEpisodes: [MediaDetailView.EpisodeItem] = []
    public var selectedMangaChapters: [MediaDetailView.MangaChapterItem] = []
    public var activeStreamURL: URL?

    // Dashboard State
    public var upNextItems: [UpNextQueueView.QueueEntry] = []
    public var watchingItems: [MediaCard.Item] = []
    public var trendingItems: [MediaCard.Item] = []
    public var searchResults: [MediaCard.Item] = []

    public init() {}

    /// Initializes the headless Rust engine and opens the SQLite registry.
    public func initialize(anilistToken: String? = nil, tmdbKey: String? = nil) async {
        guard engine == nil else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dataDir = appSupport.appendingPathComponent("AniCat", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

            // Zero-Login iCloud Sync: retrieve token from iCloud Keychain if not explicitly provided
            let token = anilistToken ?? iCloudSyncService.shared.getAniListToken()

            let coreEngine = try AnicatEngine(
                dataDir: dataDir.path,
                anilistToken: token,
                tmdbKey: tmdbKey
            )
            self.engine = coreEngine

            let port = try await coreEngine.streamPort()
            print("AniCat Rust Engine ready! Dynamic stream server on port: \(port)")
            self.isInitialized = true

            // Bonjour Local Swarm Offload: advertise on macOS, browse on iOS
            #if os(macOS)
            BonjourDiscovery.shared.startAdvertising(port: port)
            #else
            BonjourDiscovery.shared.startBrowsing()
            #endif

            // Preload initial trending shows
            await loadInitialCatalog()
        } catch {
            self.errorMessage = "Failed to start AniCat Engine: \(error.localizedDescription)"
            print(errorMessage!)
        }
    }

    /// Search anime across AniList catalog via the Rust engine.
    public func search(query: String) async {
        guard let engine, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let summaries = try await engine.searchAnime(query: query)
            self.searchResults = summaries.map { summary in
                MediaCard.Item(
                    id: summary.catalogId,
                    title: summary.title,
                    coverImageURL: URL(string: summary.coverImage),
                    isManga: false,
                    score: summary.averageScore.map { Int($0) },
                    totalEpisodesOrChapters: summary.episodes.map { Int($0) }
                )
            }
        } catch {
            print("Search failed: \(error)")
        }
    }

    /// Resolves a torrent release and prepares the stream URL for playback.
    public func resolveAndPlay(
        catalog: FfiCatalog = .anilist,
        catalogId: Int64,
        episode: Int64,
        title: String? = nil
    ) async throws -> URL {
        guard let engine else {
            throw NSError(domain: "AniCat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

        isLoading = true
        defer { isLoading = false }

        let req = StreamRequest(
            catalog: catalog,
            catalogId: catalogId,
            episode: episode,
            title: title,
            preferDub: false,
            chosenName: nil
        )

        let handle = try await engine.resolveStream(req: req)
        guard let streamURL = URL(string: handle.url) else {
            throw NSError(domain: "AniCat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid stream URL: \(handle.url)"])
        }

        self.activeStreamURL = streamURL

        // Apple Handoff: broadcast current playback activity to iPhone / iPad / Mac
        ContinuityManager.shared.advertisePlayback(
            catalogId: catalogId,
            title: title ?? "Anime",
            episode: Int(episode),
            timePositionSeconds: 0
        )

        return streamURL
    }

    /// Stops playback and clears the Apple Handoff broadcast.
    public func stopPlayback() {
        self.activeStreamURL = nil
        ContinuityManager.shared.stopAdvertising()
    }

    /// Loads trending and default shows to populate the dashboard.
    private func loadInitialCatalog() async {
        guard let engine else { return }
        do {
            let trending = try await engine.searchAnime(query: "Frieren")
            self.trendingItems = trending.map { s in
                MediaCard.Item(
                    id: s.catalogId,
                    title: s.title,
                    coverImageURL: URL(string: s.coverImage),
                    score: s.averageScore.map { Int($0) },
                    totalEpisodesOrChapters: s.episodes.map { Int($0) }
                )
            }
            
            // Seed a sample Up Next entry for verification
            if let first = trending.first {
                self.upNextItems = [
                    UpNextQueueView.QueueEntry(
                        id: first.catalogId,
                        title: first.title,
                        thumbnailURL: URL(string: first.coverImage),
                        nextEpisodeOrChapter: 1,
                        totalCount: Int(first.episodes ?? 28),
                        progressPercent: 0,
                        watchedTimeAgo: nil,
                        hasNewEpisode: true,
                        unit: "EP"
                    )
                ]
            }
        } catch {
            print("Failed to load initial catalog: \(error)")
        }
    }
}
