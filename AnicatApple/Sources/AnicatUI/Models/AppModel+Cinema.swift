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
    public struct CinemaShelf: Identifiable, Sendable, Equatable {
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
        currentNavSection = .upNext
        closeDetail()
        if mode == .cinema, cinemaShelves.isEmpty {
            Task { await loadCinemaHome() }
        }
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

    /// Films and series matching the search field's text.
    public func searchCinema(_ query: String) async {
        guard let engine, cinemaAvailable else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cinemaSearchResults = []
            return
        }
        let results = (try? await engine.searchCinema(query: trimmed, limit: 40)) ?? []
        // The field may have moved on while this was in flight; the anime
        // search guards the same way.
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        cinemaSearchResults = results.map(Self.cinemaCard)
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

        defer { loadingCatalogId = nil }
        guard let d = try? await engine.cinemaDetail(catalog: ffiCatalog, catalogId: id) else {
            isDetailLoading = false
            errorMessage = "Could not load this title from TMDB."
            return
        }
        guard currentDetailCatalog == catalog, selectedMediaDetails?.id == id else { return }

        selectedEpisodes = Self.episodeItems(from: d)
        // Built here rather than through the AniList path's own mapping: half
        // of what that fills in -- the list entry, the score, the fixtures
        // that stand in for personal data in screenshot mode -- is AniList's
        // own and has no counterpart on a TMDB title.
        let details = HeroBanner.Details(
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
