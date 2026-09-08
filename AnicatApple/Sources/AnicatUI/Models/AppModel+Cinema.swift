import SwiftUI
import AnicatCoreKit

/// Cinema mode: films and series from TMDB.
///
/// A parallel world rather than more shelves in the anime one. The two
/// catalogs number their titles independently -- AniList 550, TMDB movie 550
/// and TMDB series 550 are three unrelated titles -- so a blended shelf could
/// not say which id a card was holding, and the detail page it opened would
/// be a coin flip. Everything below therefore carries a catalog beside every
/// id, exactly as the engine's `MediaKey` does.
///
/// What is *not* duplicated is playback: `resolveAndPlay` has taken a catalog
/// since it was written, the registry keys watch history on one, and the
/// engine's `resolve_cinema_stream` picks a release by year or by SxxEyy.
/// Pressing play on a film runs the same path as pressing play on an episode.
extension AppModel {
    /// One row of the cinema home page.
    public struct CinemaShelf: Identifiable, Sendable, Equatable, Codable {
        /// The engine's own row name (`trending_movies`), which is both the
        /// id and what `cinemaRow` is called with.
        public let id: String
        public let title: String
        public let items: [MediaCard.Item]
    }

    static func loadAppMode() -> AppMode {
        let raw = UserDefaults.standard.string(forKey: appModeDefaultsKey) ?? ""
        return AppMode(rawValue: raw) ?? .anime
    }

    /// The heading for one of the engine's row names.
    ///
    /// Written here rather than in the engine because it is display text: the
    /// engine names the TMDB endpoint, the app decides what to call it. An
    /// unknown row still gets a readable heading rather than being dropped,
    /// since the engine is the side that decides which rows exist.
    nonisolated static func cinemaShelfTitle(_ kind: String) -> String {
        switch kind {
        case "trending_movies": return "Trending Films"
        case "trending_series": return "Trending Series"
        case "popular_movies": return "Popular Films"
        case "popular_series": return "Popular Series"
        case "top_movies": return "Top Rated Films"
        case "top_series": return "Top Rated Series"
        case "upcoming_movies": return "Coming Soon"
        case "airing_series": return "On the Air"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// A cinema card, with the catalog its id belongs to carried on it.
    nonisolated static func cinemaCard(_ summary: MediaSummary) -> MediaCard.Item {
        MediaCard.Item(
            id: summary.catalogId,
            title: summary.title,
            coverImageURL: URL(string: summary.coverImage),
            score: summary.averageScore.map(Int.init),
            totalEpisodesOrChapters: summary.episodes.map(Int.init),
            catalog: summary.catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
        )
    }

    /// Switches worlds. The home page each mode lands on is loaded on the
    /// way in rather than on first draw, so the switch is not a blank page
    /// followed by shelves appearing one by one.
    public func setAppMode(_ mode: AppMode) {
        guard mode != appMode else { return }
        guard mode == .anime || cinemaAvailable else { return }
        appMode = mode
        // A section the new mode does not have would leave the rail with
        // nothing highlighted and the content column on a page that mode
        // cannot fill -- Manga in cinema, Coming Soon's cinema rows in anime.
        if !SidebarView.NavSection.browseItems(for: mode).contains(currentNavSection),
           !SidebarView.NavSection.systemItems.contains(currentNavSection) {
            currentNavSection = .upNext
        }
        closeDetail()
        if mode == .cinema {
            Task {
                if cinemaShelves.isEmpty { await loadCinemaHome() }
                await loadCinemaLibrary()
            }
        }
        loadWatchStats()
    }

    /// Fills the cinema home rows.
    ///
    /// The rows are fetched together: they are eight independent TMDB
    /// endpoints, and serially this is eight round trips stacked end to end
    /// on a page that shows nothing until the last of them lands. A row that
    /// fails contributes nothing and does not take the page down with it --
    /// TMDB retires an endpoint far more readily than it retires the API.
    public func loadCinemaHome() async {
        guard let engine, cinemaAvailable else { return }
        isCinemaLoading = cinemaShelves.isEmpty
        defer { isCinemaLoading = false }

        let kinds = engine.cinemaRowKinds()
        var built: [CinemaShelf] = []
        var failure: String?
        await withTaskGroup(of: (Int, [MediaSummary], String?).self) { group in
            for (index, kind) in kinds.enumerated() {
                group.addTask {
                    do {
                        return (index, try await engine.cinemaRow(kind: kind, page: 1), nil)
                    } catch {
                        return (index, [], "\(error)")
                    }
                }
            }
            var byIndex: [Int: [MediaSummary]] = [:]
            for await (index, rows, error) in group {
                byIndex[index] = rows
                if failure == nil { failure = error }
            }
            for (index, kind) in kinds.enumerated() {
                let rows = byIndex[index] ?? []
                guard !rows.isEmpty else { continue }
                built.append(
                    CinemaShelf(
                        id: kind,
                        title: Self.cinemaShelfTitle(kind),
                        items: rows.map(Self.cinemaCard)
                    )
                )
            }
        }
        cinemaShelves = built
        // Only when nothing at all arrived: one retired endpoint out of eight
        // is not a page worth explaining away.
        cinemaError = built.isEmpty ? failure : nil
    }

    /// The Search section's results: a keyword search when there is text in
    /// the field, a filtered browse when there is not.
    ///
    /// TMDB will not do both at once -- `/search` ignores a genre and
    /// `/discover` ignores a query -- so this picks one rather than
    /// pretending the filter row applies to a keyword search.
    public func searchCinema(_ query: String, page: Int32 = 1, append: Bool = false) async {
        guard let engine, cinemaAvailable else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if append { isLoadingMoreCinema = true }
        defer { isLoadingMoreCinema = false }

        let results: [MediaSummary]
        if trimmed.isEmpty {
            results = (try? await engine.cinemaDiscover(
                isSeries: cinemaFilter.isSeries,
                genreId: cinemaFilter.genreId,
                year: cinemaFilter.year.map(Int32.init),
                sort: cinemaFilter.sort,
                page: page
            )) ?? []
        } else {
            results = (try? await engine.searchCinema(query: trimmed, limit: 40, page: page)) ?? []
            // The field may have moved on while this was in flight; the anime
            // search guards the same way.
            guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        }

        let cards = results.map(Self.cinemaCard)
        cinemaSearchResults = append ? cinemaSearchResults + cards : cards
        cinemaSearchPage = page
        // TMDB answers twenty to a page and says nothing useful about the
        // total for a filtered browse, so a short page is the end of it.
        cinemaSearchHasMore = results.count >= 20
    }

    /// The genre list behind the filter row. Loaded once per kind per
    /// launch; the engine caches it for six hours on top of that.
    public func loadCinemaGenres() async {
        guard let engine, cinemaAvailable else { return }
        let rows = (try? await engine.cinemaGenres(isSeries: cinemaFilter.isSeries)) ?? []
        cinemaGenres = rows
    }

    /// Re-runs the Search section after a filter change, from page one --
    /// keeping the old page number would ask for page 4 of a list nobody has
    /// seen page 1 of.
    public func applyCinemaFilter(_ change: (inout CinemaFilter) -> Void) {
        var filter = cinemaFilter
        change(&filter)
        guard filter != cinemaFilter else { return }
        let kindChanged = filter.isSeries != cinemaFilter.isSeries
        cinemaFilter = filter
        Task {
            if kindChanged {
                // Film genres and series genres are different lists, and a
                // genre id from one means something else in the other.
                cinemaFilter.genreId = nil
                await loadCinemaGenres()
            }
            await searchCinema(searchQuery, page: 1, append: false)
        }
    }

    /// The palette's own search: a handful of matches, no state written.
    /// `searchCinema` fills the Search section and would fight the field
    /// there with what someone typed into ⌘K.
    public func quickSearchCinema(_ query: String) async -> [MediaCard.Item] {
        guard let engine, cinemaAvailable else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let results = (try? await engine.searchCinema(query: trimmed, limit: 8, page: 1)) ?? []
        return results.map(Self.cinemaCard)
    }

    /// Opens a cinema card's detail page.
    ///
    /// A separate entry point from `openDetail`, which is AniList's: that
    /// path keys its snapshot cache, its history stack and its refreshes on
    /// `(id, isManga)` alone, and a TMDB id dropped into it would collide
    /// with whatever anime shares the number. This one writes the same
    /// observable state the page draws from and marks the catalog, so every
    /// refresh path on that page knows not to run.
    public func openCinemaDetail(
        catalog: MediaCard.CardCatalog,
        id: Int64,
        title: String? = nil,
        coverURL: URL? = nil
    ) async {
        guard let engine, catalog != .anilist else { return }
        let ffiCatalog: FfiCatalog = catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv

        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        currentDetailCatalog = catalog
        loadingCatalogId = id

        // Render the last snapshot before the fetch, exactly as the AniList
        // path does. Without it every open of a title already seen was a
        // spinner for as long as TMDB took, which is what made cinema feel
        // slower than anime rather than any difference in the animations.
        cinemaExtras = nil
        cinemaListStatus = try? engine.cinemaListStatus(
            catalog: catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv, catalogId: id
        )
        let cached = DetailCache.load(id: id, isManga: false, catalog: catalog)
        if let cached {
            isDetailLoading = false
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = cached.episodes
                selectedMangaChapters = []
                selectedRelations = cached.relations
                selectedRecommendations = cached.recommendations
                selectedCharacters = cached.characters
                selectedDiscussions = []
                selectedMediaDetails = cached.details
            }
        } else {
            isDetailLoading = true
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = []
                selectedMangaChapters = []
                selectedRelations = []
                selectedRecommendations = []
                selectedCharacters = []
                selectedDiscussions = []
                selectedMediaDetails = HeroBanner.Details(
                    id: id,
                    title: title ?? "Loading...",
                    coverURL: coverURL,
                    format: catalog == .tmdbMovie ? "MOVIE" : "TV"
                )
            }
        }

        defer { loadingCatalogId = nil }
        guard let d = try? await engine.cinemaDetail(catalog: ffiCatalog, catalogId: id) else {
            isDetailLoading = false
            // A snapshot on screen is better than an error over it: the page
            // is already readable and the fetch was only a refresh.
            if cached == nil { errorMessage = "Could not load this title from TMDB." }
            return
        }
        guard currentDetailCatalog == catalog, selectedMediaDetails?.id == id else { return }

        selectedEpisodes = Self.episodeItems(from: d)
        let details = Self.cinemaDetails(from: d)
        withAnimation(.easeInOut(duration: 0.24)) {
            selectedMediaDetails = details
            selectedRecommendations = d.recommendations.map {
                MediaDetailView.RecommendationItem(
                    id: $0.catalogId,
                    title: $0.title,
                    format: $0.format,
                    coverURL: URL(string: $0.coverImage),
                    averageScore: $0.averageScore.map(Int.init)
                )
            }
            isDetailLoading = false
        }

        // The cast and the facts panel come from the same cached TMDB detail
        // the page just loaded, so these are two more calls and no more
        // requests. Fetched after the page is on screen rather than before:
        // nothing above the tabs waits on them.
        activeDetailExtrasTask = Task { [weak self] in
            guard let self else { return }
            async let castTask = engine.cinemaCast(catalog: ffiCatalog, catalogId: id)
            async let extrasTask = engine.cinemaExtras(catalog: ffiCatalog, catalogId: id)
            let cast = (try? await castTask) ?? []
            let extras = try? await extrasTask
            guard !Task.isCancelled,
                  self.currentDetailCatalog == catalog,
                  self.selectedMediaDetails?.id == id else { return }
            withAnimation(.smooth(duration: 0.25)) {
                self.selectedCharacters = cast.map {
                    MediaDetailView.CharacterItem(
                        id: $0.id,
                        name: $0.name,
                        imageURL: $0.imageUrl.flatMap(URL.init(string:)),
                        role: $0.role,
                        voiceActorName: nil,
                        voiceActorImageURL: nil
                    )
                }
                self.cinemaExtras = extras
            }
        }

        DetailCache.save(
            DetailCache.Snapshot(
                details: details,
                episodes: selectedEpisodes,
                mangaChapters: [],
                relations: [],
                recommendations: selectedRecommendations,
                characters: selectedCharacters,
                discussions: []
            ),
            id: id,
            isManga: false,
            catalog: catalog
        )
    }

    /// A cinema title's header, mapped from `MediaDetail`.
    ///
    /// Built here rather than through the AniList path's own mapping: half of
    /// what that fills in -- the list entry, the score, the fixtures that
    /// stand in for personal data in screenshot mode -- is AniList's own and
    /// has no counterpart on a TMDB title. Shared with the prefetch, so a
    /// card hovered and a card opened write the same snapshot.
    nonisolated static func cinemaDetails(from d: MediaDetail) -> HeroBanner.Details {
        HeroBanner.Details(
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
            episodeCount: d.episodeCount.map(Int.init),
            resumeEpisode: d.resumeEpisode.map(Int.init),
            resumeSeconds: d.resumeSeconds.map(Int.init),
            prequel: nil,
            sequel: nil,
            listStatus: nil,
            userScore: nil,
            listEntryId: nil,
            listProgress: nil,
            isFavourite: false,
            malId: nil,
            trailerSite: d.trailerSite,
            trailerId: d.trailerId,
            trailerThumbnail: d.trailerThumbnail,
            studios: []
        )
    }

    /// Warms the snapshot for a card the pointer is over, so opening it
    /// paints from disk instead of from a spinner. Same idea as
    /// `prefetchDetail` on the AniList side, and the same background
    /// priority: it must never be what a real fetch is queued behind.
    public func prefetchCinemaDetail(catalog: MediaCard.CardCatalog, id: Int64) {
        guard let engine, catalog != .anilist, cinemaAvailable else { return }
        guard DetailCache.load(id: id, isManga: false, catalog: catalog) == nil else { return }
        guard !activePrefetches.contains(id) else { return }
        activePrefetches.insert(id)
        let ffiCatalog: FfiCatalog = catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
        Task(priority: .background) { [weak self] in
            defer { self?.activePrefetches.remove(id) }
            guard let d = try? await engine.cinemaDetail(catalog: ffiCatalog, catalogId: id) else { return }
            DetailCache.save(
                DetailCache.Snapshot(
                    details: Self.cinemaDetails(from: d),
                    episodes: Self.episodeItems(from: d),
                    mangaChapters: [],
                    relations: [],
                    recommendations: [],
                    characters: [],
                    discussions: []
                ),
                id: id,
                isManga: false,
                catalog: catalog
            )
        }
    }

    /// The catalog a cinema id belongs to, as the resume queue knows it.
    /// `UpNextQueueView.QueueEntry` carries an id and no catalog -- it
    /// predates there being two -- so the row it was built from is the
    /// answer.
    public func cinemaCatalog(forId id: Int64) -> MediaCard.CardCatalog {
        cinemaContinueWatching.first { $0.id == id }?.catalog ?? .tmdbMovie
    }

    /// Play from the resume queue: open the title's page first, then start
    /// the stream over it. Closing the player then lands on the page of what
    /// was just watched rather than back on the home rows, and a resolve
    /// failure has that page underneath it -- the same shape as the anime
    /// shelves' own Play.
    public func playCinemaFromQueue(id: Int64, episode: Int, title: String, coverURL: URL?) async {
        let catalog = cinemaCatalog(forId: id)
        await openCinemaDetail(catalog: catalog, id: id, title: title, coverURL: coverURL)
        await playCinemaEpisode(episode)
    }

    /// Puts the open title on the local list, or takes it off.
    public func setCinemaListStatus(_ status: String?) {
        guard let engine, let details = selectedMediaDetails, currentDetailCatalog != .anilist else { return }
        let catalog: FfiCatalog = currentDetailCatalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
        do {
            try engine.setCinemaListStatus(catalog: catalog, catalogId: details.id, status: status)
            cinemaListStatus = status
            playFeedback(.watchedTick)
            Task { await loadCinemaWatchlist() }
        } catch {
            errorMessage = "Could not update the list: \(error.localizedDescription)"
        }
    }

    /// The local list for the Watching section's second tab.
    public func loadCinemaWatchlist() async {
        guard let engine, cinemaAvailable else { return }
        let rows = (try? engine.cinemaList(status: cinemaWatchlistFilter)) ?? []
        var items: [MediaCard.Item] = []
        for row in rows.prefix(60) {
            let catalog: MediaCard.CardCatalog = row.catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
            guard let known = await cinemaTitle(catalog: catalog, id: row.catalogId) else { continue }
            cinemaKnownTitles[row.catalogId] = known.title
            cinemaKnownCovers[row.catalogId] = known.coverURL
            items.append(
                MediaCard.Item(
                    id: row.catalogId,
                    title: known.title,
                    coverImageURL: known.coverURL,
                    catalog: catalog
                )
            )
        }
        cinemaWatchlist = items
    }

    /// Re-reads the open cinema page after playback, so the episode row that
    /// was just watched shows its tick and the resume position moves.
    ///
    /// Not `openCinemaDetail`: that resets the page, the scroll and the
    /// season picker, which is the wrong thing to do to a page the viewer is
    /// already looking at. The TMDB detail is cached, so this is the
    /// registry's own progress and no request.
    func refreshCinemaDetailAfterPlayback(id: Int64) async {
        guard let engine, currentDetailCatalog != .anilist,
              selectedMediaDetails?.id == id else { return }
        let catalog: FfiCatalog = currentDetailCatalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
        guard let d = try? await engine.cinemaDetail(catalog: catalog, catalogId: id),
              selectedMediaDetails?.id == id else { return }
        selectedEpisodes = Self.episodeItems(from: d)
        selectedMediaDetails = Self.cinemaDetails(from: d)
    }

    /// Plays one episode of the open cinema title, or the film itself.
    public func playCinemaEpisode(_ number: Int) async {
        guard let details = selectedMediaDetails, currentDetailCatalog != .anilist else { return }
        let catalog: FfiCatalog = currentDetailCatalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
        do {
            _ = try await resolveAndPlay(
                catalog: catalog,
                catalogId: details.id,
                episode: Int64(number),
                title: details.title
            )
        } catch {
            errorMessage = "Could not play \(details.title): \(error.localizedDescription)"
            playFeedback(.error)
        }
    }
}

extension AppModel {
    /// The catalog a play from the open detail page belongs to.
    ///
    /// The page itself carries only an id -- `HeroBanner.Details` predates
    /// there being a second catalog -- so this is what keeps a press of Play
    /// on a film from resolving the anime that happens to share its number.
    public var playbackCatalogForOpenDetail: FfiCatalog {
        switch currentDetailCatalog {
        case .tmdbMovie: return .tmdbMovie
        case .tmdbTv: return .tmdbTv
        case .anilist: return .anilist
        }
    }
}

extension AppModel {
    /// Continue-watching and history for cinema mode, out of the local
    /// registry.
    ///
    /// Nothing here is AniList's: a film has no list entry and no progress
    /// anywhere but this device, so the registry is the only source and the
    /// titles have to be found separately. A title already opened has a
    /// detail snapshot on disk and costs nothing; anything else is one
    /// TMDB detail, cached for a day, and only for rows actually shown.
    public func loadCinemaLibrary() async {
        guard let engine, cinemaAvailable else { return }
        let rows = ((try? engine.watchActivity(limit: 200)) ?? [])
            .filter { $0.catalog != .anilist }
        cinemaActivity = rows

        // Newest first, one entry per title: a binge leaves ten rows for one
        // show and the shelf wants the show, not the episodes.
        var seen = Set<Int64>()
        var ordered: [ActivityRow] = []
        for row in rows.sorted(by: { $0.watchedAt > $1.watchedAt }) where seen.insert(row.catalogId).inserted {
            ordered.append(row)
        }

        var items: [MediaCard.Item] = []
        for row in ordered.prefix(24) {
            let catalog: MediaCard.CardCatalog = row.catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
            guard let known = await cinemaTitle(catalog: catalog, id: row.catalogId) else { continue }
            cinemaKnownTitles[row.catalogId] = known.title
            cinemaKnownCovers[row.catalogId] = known.coverURL
            items.append(
                MediaCard.Item(
                    id: row.catalogId,
                    title: known.title,
                    coverImageURL: known.coverURL,
                    progress: Int(row.episodeNumber),
                    catalog: catalog
                )
            )
        }
        cinemaContinueWatching = items

        // The resume queue: where each title actually stopped, which the
        // activity rows do not carry -- they say an episode was watched, not
        // how far into it. One registry read per row, no network.
        var queue: [UpNextQueueView.QueueEntry] = []
        for item in items.prefix(12) {
            let ffiCatalog: FfiCatalog = item.catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
            let episode = Int64(item.progress ?? 1)
            let progress = try? engine.getProgress(
                catalog: ffiCatalog, catalogId: item.id, episodeNumber: episode
            )
            let percent: Double = {
                guard let progress, progress.duration > 0 else { return 0 }
                return Double(progress.stopTime) / Double(progress.duration) * 100
            }()
            // Past the watched threshold the queue should offer the *next*
            // one, the same way the anime queue does, rather than replaying
            // what was finished. A film has nothing after it.
            let finished = percent >= 85
            let isFilm = item.catalog == .tmdbMovie
            if finished && isFilm { continue }
            let next = finished ? episode + 1 : episode
            queue.append(
                UpNextQueueView.QueueEntry(
                    id: item.id,
                    title: item.title,
                    thumbnailURL: item.coverImageURL,
                    nextEpisodeOrChapter: Int(next),
                    totalCount: item.totalEpisodesOrChapters ?? 0,
                    progressPercent: finished ? 0 : percent,
                    watchedTimeAgo: nil,
                    hasNewEpisode: false,
                    unit: isFilm ? "FILM" : "EP"
                )
            )
        }
        cinemaUpNext = queue
        persistHomeCache()
    }

    /// A cinema title's name and poster: from the detail snapshot if this
    /// device has one, otherwise from TMDB.
    func cinemaTitle(
        catalog: MediaCard.CardCatalog,
        id: Int64
    ) async -> (title: String, coverURL: URL?)? {
        if let snapshot = DetailCache.load(id: id, isManga: false, catalog: catalog) {
            return (snapshot.details.title, snapshot.details.coverURL)
        }
        if let cached = cinemaKnownTitles[id] {
            return (cached, cinemaKnownCovers[id])
        }
        guard let engine else { return nil }
        let ffiCatalog: FfiCatalog = catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
        guard let detail = try? await engine.cinemaDetail(catalog: ffiCatalog, catalogId: id) else {
            return nil
        }
        return (detail.title, URL(string: detail.coverImage))
    }
}
