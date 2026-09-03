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
    public var currentNavSection: SidebarView.NavSection = .upNext
    public var paletteOpen = false
    public var searchQuery: String = ""
    public var selectedMediaDetails: HeroBanner.Details?
    public var selectedEpisodes: [MediaDetailView.EpisodeItem] = []
    public var selectedMangaChapters: [MediaDetailView.MangaChapterItem] = []
    public var activeStreamURL: URL?

    // Dashboard State
    public var upNextItems: [UpNextQueueView.QueueEntry] = []
    public var watchingItems: [MediaCard.Item] = []
    public var trendingItems: [MediaCard.Item] = []
    public var searchResults: [MediaCard.Item] = []
    public var scheduleItems: [ScheduleView.ScheduleItem] = []

    // Library / Manga / Novels / History
    public var libraryItems: [MediaCard.Item] = []
    public var libraryStatus: String = "CURRENT"
    public var libraryType: String = "ANIME"
    public var mangaTrending: [MediaCard.Item] = []
    public var mangaReading: [MediaCard.Item] = []
    public var novelTrending: [MediaCard.Item] = []
    public var novelReading: [MediaCard.Item] = []
    public var viewer: ViewerProfile?
    public var activity: [ActivityRow] = []

    /// Titles for ids the History log has rows for, gathered from every list
    /// already loaded. The registry stores a `catalog_id` and nothing else —
    /// it has no idea what a show is called — so the name has to come from
    /// whatever the catalog views have already fetched.
    public var knownTitles: [Int64: String] {
        var out: [Int64: String] = [:]
        for item in watchingItems + trendingItems + libraryItems + mangaReading + novelReading + searchResults {
            out[item.id] = item.title
        }
        return out
    }

    /// Whether AniList answered with a viewer. The four catalog-backed views
    /// have nothing to show without it and say so rather than sitting empty.
    public var isSignedIn = false

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

    /// Hands a pasted token to the running engine and reloads everything.
    ///
    /// This used to route back through `initialize`, which opens with
    /// `guard engine == nil else { return }` — the engine is built at launch,
    /// before any token exists, so that guard fired every time and the token
    /// reached the Keychain but never the AniList client. Saving appeared to
    /// do nothing at all.
    public func signIn(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !trimmed.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        engine.setAnilistToken(token: trimmed)
        let profile = try? await engine.viewerProfile()
        guard profile != nil else {
            isSignedIn = false
            errorMessage = "AniList rejected that token."
            return
        }
        _ = iCloudSyncService.shared.saveAniListToken(trimmed)
        viewer = profile
        isSignedIn = true
        errorMessage = nil
        await refreshAll()
    }

    public func signOut() {
        engine?.setAnilistToken(token: nil)
        iCloudSyncService.shared.deleteAniListToken()
        isSignedIn = false
        viewer = nil
        watchingItems = []
        upNextItems = []
        scheduleItems = []
        libraryItems = []
        mangaReading = []
        novelReading = []
    }

    /// Everything the signed-in views draw from, in one pass.
    public func refreshAll() async {
        await loadInitialCatalog()
        await loadLibrary()
        await loadReadingShelves()
        await loadHistory()
    }

    /// Opens the detail page for a title, replacing the fabricated stand-in
    /// that used to fill it: 28 episodes numbered 1...28, every one titled
    /// "Episode N", a hardcoded synopsis of "An extraordinary journey begins."
    /// and a score of 92 regardless of the show.
    public func openDetail(catalogId: Int64, isManga: Bool = false) async {
        guard let engine else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let d = try await engine.mediaDetail(catalogId: catalogId, isManga: isManga)
            selectedMediaDetails = HeroBanner.Details(
                id: d.catalogId,
                title: d.title,
                romajiTitle: d.romajiTitle,
                bannerURL: d.bannerImage.flatMap(URL.init(string:)),
                coverURL: URL(string: d.coverImage),
                format: d.format,
                year: d.year.map(Int.init),
                studio: d.studio,
                synopsis: d.synopsis,
                genres: d.genres,
                averageScore: d.averageScore.map(Int.init),
                nextEpisodeText: nil,
                status: d.status,
                episodeCount: (d.episodeCount ?? d.chapterCount).map(Int.init),
                resumeEpisode: d.resumeEpisode.map(Int.init),
                resumeSeconds: d.resumeSeconds.map(Int.init),
                prequel: d.prequel.map(Self.relation),
                sequel: d.sequel.map(Self.relation)
            )
            selectedEpisodes = d.episodes.map { e in
                MediaDetailView.EpisodeItem(
                    id: Int64(e.number),
                    number: Int(e.number),
                    title: e.title,
                    thumbnailURL: e.thumbnail.flatMap(URL.init(string:)),
                    isWatched: e.isWatched,
                    progressPercent: e.progressPercent,
                    runtimeMinutes: e.runtimeMinutes.map(Int.init)
                )
            }
            selectedMangaChapters = []
            if isManga {
                await loadMangaChapters(title: d.title, anilistId: catalogId)
            }
        } catch {
            errorMessage = "Could not open that title: \(error.localizedDescription)"
        }
    }

    /// MangaDex has no AniList ids of its own to search by, so the title is
    /// the query and `links.al` is what confirms the match.
    private func loadMangaChapters(title: String, anilistId: Int64) async {
        guard let engine else { return }
        guard let match = try? await engine.searchManga(query: title, anilistId: anilistId),
              let first = match.first else { return }
        let chapters = (try? await engine.getMangaChapters(mangaId: first.id)) ?? []
        selectedMangaChapters = chapters.map {
            MediaDetailView.MangaChapterItem(id: $0.id, number: $0.number, title: $0.title)
        }
    }

    static func relation(_ r: RelatedTitle) -> HeroBanner.Details.Relation {
        HeroBanner.Details.Relation(
            id: r.catalogId,
            title: r.title,
            format: r.format,
            coverURL: URL(string: r.coverImage)
        )
    }

    /// Maps the engine's flat summary onto a card. One place, so a card in
    /// the Library draws its progress tick from the same fields as one in a
    /// home shelf.
    static func card(_ s: MediaSummary) -> MediaCard.Item {
        let total = s.episodes ?? s.chapters
        let progress = s.progress.map { Int($0) }
        let released = s.nextEpisode.map { Int($0) - 1 } ?? total.map { Int($0) }
        return MediaCard.Item(
            id: s.catalogId,
            title: s.title,
            coverImageURL: URL(string: s.coverImage),
            isManga: s.episodes == nil && s.chapters != nil,
            score: s.averageScore.map { Int($0) },
            progress: progress,
            totalEpisodesOrChapters: total.map { Int($0) },
            hasNewEpisode: {
                guard let p = progress, let r = released else { return false }
                return s.listStatus == "CURRENT" && p < r
            }()
        )
    }

    /// Loads the user's list for one status bucket.
    public func loadLibrary(status: String? = nil, type: String? = nil) async {
        guard let engine else { return }
        if let status { libraryStatus = status }
        if let type { libraryType = type }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await engine.userList(status: libraryStatus, mediaType: libraryType)
            libraryItems = rows.map(Self.card)
        } catch {
            libraryItems = []
            print("Library load failed: \(error)")
        }
    }

    /// Manga and light novels share a shape: a trending shelf plus whatever
    /// the user is already reading. Novels are AniList's `NOVEL` format under
    /// the `MANGA` type, not a type of their own.
    public func loadReadingShelves() async {
        guard let engine else { return }
        // Sequential rather than `async let`: the engine is a shared
        // reference and the strict-concurrency checker rejects sending it
        // into concurrent children. The three calls are cached AniList reads,
        // so the cost of serialising them is a few hundred milliseconds once
        // per visit, not per interaction.
        let trendingManga = (try? await engine.trending(mediaType: "MANGA", format: nil, limit: 24)) ?? []
        let novels = (try? await engine.trending(mediaType: "MANGA", format: "NOVEL", limit: 24)) ?? []
        let readingRows = (try? await engine.userList(status: "CURRENT", mediaType: "MANGA")) ?? []

        mangaTrending = trendingManga.map(Self.card)
        novelTrending = novels.map(Self.card)
        mangaReading = readingRows.filter { $0.format != "NOVEL" }.map(Self.card)
        novelReading = readingRows.filter { $0.format == "NOVEL" }.map(Self.card)
    }

    /// The History view: the AniList profile when signed in, and the local
    /// watch log either way — the registry recorded that without a token.
    public func loadHistory() async {
        guard let engine else { return }
        activity = (try? engine.watchActivity(limit: 500)) ?? []
        viewer = try? await engine.viewerProfile()
        isSignedIn = viewer != nil
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

    /// Fills the home page.
    ///
    /// Everything here is real. This used to search for the literal string
    /// "Frieren" and then invent an Up Next entry and a week of airing times
    /// ("Monday, September 4", "in 2h 15m") out of the results — which made
    /// the app look populated in a screenshot while showing nothing a user
    /// could act on, and made the Schedule view a fiction.
    private func loadInitialCatalog() async {
        guard let engine else { return }

        let trending = (try? await engine.trending(mediaType: "ANIME", format: nil, limit: 24)) ?? []
        trendingItems = trending.map(Self.card)

        let watching = (try? await engine.userList(status: "CURRENT", mediaType: "ANIME")) ?? []
        let profile = try? await engine.viewerProfile()
        isSignedIn = profile != nil
        viewer = profile
        watchingItems = watching.map(Self.card)

        upNextItems = watching.compactMap { s in
            let progress = Int(s.progress ?? 0)
            let total = Int(s.episodes ?? 0)
            let released = s.nextEpisode.map { Int($0) - 1 } ?? total
            return UpNextQueueView.QueueEntry(
                id: s.catalogId,
                title: s.title,
                thumbnailURL: URL(string: s.coverImage),
                nextEpisodeOrChapter: progress + 1,
                totalCount: total,
                progressPercent: total > 0 ? Double(progress) / Double(total) * 100 : 0,
                watchedTimeAgo: s.updatedAt.map(Self.relativeTime),
                hasNewEpisode: progress < released,
                unit: "EP"
            )
        }

        // Only shows AniList actually has an airing time for. A show with no
        // `nextAiringEpisode` is not on the schedule; it is finished, or
        // between seasons.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMMM d"
        scheduleItems = watching.compactMap { s in
            guard let at = s.nextAiringAt, let ep = s.nextEpisode else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(at))
            return ScheduleView.ScheduleItem(
                id: s.catalogId,
                title: s.title,
                coverImageURL: URL(string: s.coverImage),
                episodeNumber: Int(ep),
                airingTimeText: formatter.string(from: date),
                countdownText: Self.countdown(to: date),
                dayGroup: dayFormatter.string(from: date)
            )
        }
        .sorted { ($0.episodeNumber, $0.dayGroup) < ($1.episodeNumber, $1.dayGroup) }
    }

    /// "6h ago", "3d ago" — the same buckets `relativeDay` uses on the web.
    static func relativeTime(_ unixSeconds: Int64) -> String {
        let seconds = Date().timeIntervalSince1970 - TimeInterval(unixSeconds)
        let hours = Int(seconds / 3600)
        if hours < 1 { return "just now" }
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        return "\(days / 7)w ago"
    }

    static func countdown(to date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "aired" }
        let hours = seconds / 3600
        if hours < 24 { return "in \(hours)h \(seconds % 3600 / 60)m" }
        return "in \(hours / 24)d \(hours % 24)h"
    }
}
