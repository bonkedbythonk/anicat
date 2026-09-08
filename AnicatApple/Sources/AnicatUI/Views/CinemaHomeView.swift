import SwiftUI

/// Cinema mode's home page: a search field, and the TMDB rows beneath it.
///
/// One view for both the Up Next and Search sections while the app is in
/// cinema mode. The anime side splits them because its search carries
/// formats, genre filters, sorts and a discover grid, none of which TMDB's
/// two search endpoints take; here a query is a query, so a second screen
/// would be the same field twice.
struct CinemaHomeView: View {
    /// Which of cinema mode's sections this is drawing.
    ///
    /// One view for four rail entries because they differ only in which
    /// shelves they show: the search field, the cards, the morph and the
    /// empty states are the same, and four files would be four copies of
    /// them drifting apart.
    enum Page {
        case home
        /// One kind on its own, with the filter row defaulted to it -- the
        /// same split by kind the anime rail makes with Manga and Light
        /// Novels.
        case films
        case series
        case watching
        case search
    }

    let model: AppModel
    let namespace: Namespace.ID
    var page: Page = .home
    /// Focused on arrival when the viewer got here by pressing Search rather
    /// than Home -- the section is otherwise identical, and landing on it
    /// with the caret nowhere would read as the wrong page having opened.
    let focusSearchOnAppear: Bool

    /// The shelves this page draws, by the engine's own row names.
    private var shelves: [AppModel.CinemaShelf] {
        switch page {
        case .films:
            return model.cinemaShelves.filter { $0.id.hasSuffix("_movies") }
        case .series:
            return model.cinemaShelves.filter { $0.id.hasSuffix("_series") }
        case .home, .search, .watching:
            return model.cinemaShelves
        }
    }

    /// Films and Series carry the same filter row Search has, defaulted to
    /// their own kind: the rows above are a fixed selection, and this is how
    /// you get past it to "action, 1999, top rated".
    private var showsFilterRow: Bool {
        page == .films || page == .series || (page == .search && !isSearching)
    }

    @FocusState private var searchFocused: Bool

    enum WatchingTab: Hashable { case continueWatching, list }
    @State private var watchingTab: WatchingTab = .continueWatching

    private var results: [MediaCard.Item] { model.cinemaSearchResults }
    private var isSearching: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                searchField

                if page == .search {
                    if !isSearching { filterRow }
                    resultsGrid
                } else if page == .films || page == .series {
                    filterRow
                    ForEach(shelves) { shelf in
                        shelfRow(shelf)
                    }
                    if !model.cinemaSearchResults.isEmpty {
                        resultsGrid
                    }
                } else if isSearching {
                    resultsGrid
                } else if page == .home, !model.cinemaUpNext.isEmpty {
                    upNext
                    ForEach(shelves) { shelf in
                        shelfRow(shelf)
                    }
                } else if page == .watching {
                    watching
                } else if shelves.isEmpty {
                    if model.isCinemaLoading {
                        MediaRowSkeleton(title: "Trending Films")
                        MediaRowSkeleton(title: "Trending Series")
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(shelves) { shelf in
                        shelfRow(shelf)
                    }
                }

                // Every row above is TMDB's data, and their terms ask for the
                // mark wherever it is shown -- not only on a settings page.
                TMDBAttribution()
                    .padding(.top, 8)
            }
            .padding(.horizontal, SumiTheme.spaceLg)
            .padding(.vertical, 24)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            if model.cinemaShelves.isEmpty { await model.loadCinemaHome() }
            if page == .watching || page == .home { await model.loadCinemaLibrary() }
            if showsFilterRow {
                // Films and Series set the kind on arrival, so the filter row
                // and the browse under it agree with the section you are in.
                if page == .films || page == .series {
                    model.applyCinemaFilter { $0.isSeries = (page == .series) }
                }
                if model.cinemaGenres.isEmpty { await model.loadCinemaGenres() }
                // The section opens on a browse rather than on nothing.
                if model.cinemaSearchResults.isEmpty { await model.searchCinema("") }
            }
            if focusSearchOnAppear { searchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Text("Search")
                .sumiTabularMono(size: 11)
                .foregroundColor(SumiTheme.muted)

            TextField("Films and series", text: Binding(
                get: { model.searchQuery },
                set: { model.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundColor(SumiTheme.foreground)
            .focused($searchFocused)
            .onSubmit {
                Task { await model.searchCinema(model.searchQuery) }
            }

            if isSearching {
                Button {
                    model.searchQuery = ""
                    model.cinemaSearchResults = []
                } label: {
                    Text("Clear")
                        .sumiTabularMono(size: 11)
                        .foregroundColor(SumiTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SumiTheme.foreground.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(SumiTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var resultsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(results.isEmpty ? "No matches" : "\(results.count) results")
                .sumiTabularMono(size: 11.5)
                .foregroundColor(SumiTheme.muted)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)],
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(results) { item in
                    card(item, shelf: "cinemaSearch")
                }
            }

            if model.cinemaSearchHasMore {
                Button {
                    Task {
                        await model.searchCinema(
                            model.searchQuery,
                            page: model.cinemaSearchPage + 1,
                            append: true
                        )
                    }
                } label: {
                    Text(model.isLoadingMoreCinema ? "Loading…" : "Load more")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(SumiTheme.indigo)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(SumiTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.sumiPressable)
                .disabled(model.isLoadingMoreCinema)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
            }
        }
    }

    /// Films or series, a genre, a year and a sort -- TMDB's `/discover`,
    /// which is the only way to ask for "action films from 1999". Shown on
    /// the Search section with an empty field: with text in it the keyword
    /// search runs instead, and TMDB ignores the filters there rather than
    /// combining them.
    private var filterRow: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { model.cinemaFilter.isSeries },
                set: { next in model.applyCinemaFilter { $0.isSeries = next } }
            )) {
                Text("Films").tag(false)
                Text("Series").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("", selection: Binding(
                get: { model.cinemaFilter.genreId ?? -1 },
                set: { next in model.applyCinemaFilter { $0.genreId = next == -1 ? nil : next } }
            )) {
                Text("Any genre").tag(Int64(-1))
                ForEach(model.cinemaGenres, id: \.id) { genre in
                    Text(genre.name).tag(genre.id)
                }
            }
            .frame(maxWidth: 170)

            Picker("", selection: Binding(
                get: { model.cinemaFilter.year ?? -1 },
                set: { next in model.applyCinemaFilter { $0.year = next == -1 ? nil : next } }
            )) {
                Text("Any year").tag(-1)
                ForEach(Self.years, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .frame(maxWidth: 130)

            Picker("", selection: Binding(
                get: { model.cinemaFilter.sort },
                set: { next in model.applyCinemaFilter { $0.sort = next } }
            )) {
                Text("Popular").tag("popularity.desc")
                Text("Top rated").tag("vote_average.desc")
                Text("Newest").tag("primary_release_date.desc")
            }
            .frame(maxWidth: 140)

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundColor(SumiTheme.foreground)
    }

    /// Back to the first year TMDB has much of anything for. Listing every
    /// year to 1874 makes the picker a scroll rather than a choice.
    private static let years: [Int] = {
        let current = Calendar.current.component(.year, from: Date())
        return Array((1950...(current + 1)).reversed())
    }()

    private func shelfRow(_ shelf: AppModel.CinemaShelf) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(shelf.title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)

                Spacer()

                Text("\(shelf.items.count) titles")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items) { item in
                        card(item, shelf: shelf.id).frame(width: 180)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The poster that grows into the detail page, keyed by shelf *and*
    /// catalog. The same film sits in Trending and in Popular at once, and
    /// two morph sources for one key is undefined behaviour -- the bug that
    /// lost posters on the anime side -- so the key names the shelf, and the
    /// catalog is in it because a TMDB id and an AniList id collide.
    private func card(_ item: MediaCard.Item, shelf: String) -> some View {
        let catalog = item.catalog ?? .tmdbMovie
        let key = "cinema:\(catalog.rawValue):\(shelf):\(item.id)"
        return MediaCard(
            item: item,
            namespace: model.openingDetailSourceKey == key ? namespace : nil,
            onPrefetch: { model.prefetchCinemaDetail(catalog: catalog, id: item.id) }
        ) {
            model.openingDetailSourceKey = key
            Task {
                await model.openCinemaDetail(
                    catalog: catalog,
                    id: item.id,
                    title: item.title,
                    coverURL: item.coverImageURL
                )
            }
        }
        .equatable()
    }

    /// The resume queue, in the same component the anime home uses -- so a
    /// film picks up where it stopped with one press, instead of being found
    /// again through a shelf and a page.
    private var upNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text("Up Next")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)
                Spacer()
                Text("\(model.cinemaUpNext.count) waiting")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }

            UpNextQueueView(
                items: model.cinemaUpNext,
                namespace: namespace,
                openingSourceKey: model.openingDetailSourceKey,
                shelfKey: "cinemaUpNext",
                onSelect: { entry in
                    let catalog = model.cinemaCatalog(forId: entry.id)
                    model.openingDetailSourceKey = "cinemaUpNext:\(entry.id)"
                    Task {
                        await model.openCinemaDetail(
                            catalog: catalog,
                            id: entry.id,
                            title: entry.title,
                            coverURL: entry.thumbnailURL
                        )
                    }
                },
                onPlay: { entry in
                    Task {
                        await model.playCinemaFromQueue(
                            id: entry.id,
                            episode: entry.nextEpisodeOrChapter,
                            title: entry.title,
                            coverURL: entry.thumbnailURL
                        )
                    }
                }
            )
        }
    }

    /// Everything with a stored position, newest first. Local only: a film
    /// has no list entry anywhere, so this is the registry and nothing else.
    @ViewBuilder
    private var watching: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Two lists, not one: what was started and what was saved for
            // later answer different questions, and a film sitting in both
            // would otherwise appear twice with no way to tell why.
            Picker("", selection: $watchingTab) {
                Text("Continue").tag(WatchingTab.continueWatching)
                Text("Watchlist").tag(WatchingTab.list)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if watchingTab == .list {
                watchlist
            } else {
                continueWatching
            }
        }
        .task(id: watchingTab) {
            if watchingTab == .list { await model.loadCinemaWatchlist() }
        }
    }

    /// The local list, by status. Nothing here is on AniList: a TMDB title
    /// has no entry there, so this is the registry and this device.
    @ViewBuilder
    private var watchlist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(
                get: { model.cinemaWatchlistFilter },
                set: { next in
                    model.cinemaWatchlistFilter = next
                    Task { await model.loadCinemaWatchlist() }
                }
            )) {
                Text("Planning").tag("PLANNING")
                Text("Watching").tag("CURRENT")
                Text("Completed").tag("COMPLETED")
                Text("Dropped").tag("DROPPED")
            }
            .frame(maxWidth: 160)
            .font(.system(size: 12))

            if model.cinemaWatchlist.isEmpty {
                Text("Nothing on this list yet. Add a film or series from its page.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(model.cinemaWatchlist) { item in
                        card(item, shelf: "cinemaWatchlist")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var continueWatching: some View {
        if model.cinemaContinueWatching.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing started yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                Text("Films and series you play show up here, with the position they stopped at. It is kept on this device -- nothing is sent anywhere.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("CONTINUE WATCHING")
                    .sumiTabularMono(size: 9.5, weight: .bold)
                    .foregroundColor(SumiTheme.muted)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(model.cinemaContinueWatching) { item in
                        card(item, shelf: "cinemaWatching")
                    }
                }
            }
        }
    }

    /// TMDB refused the key rather than failing to answer. Worth its own
    /// message: retrying is the one thing that cannot fix it.
    private var keyWasRejected: Bool {
        model.cinemaError?.contains("tmdb_unauthorized") == true
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(keyWasRejected ? "TMDB rejected the key" : "Nothing to show")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            Text(keyWasRejected
                 ? "Films and series need a key TMDB accepts. Clear the key in Settings to fall back to the built-in one, or paste a working v3 key or v4 read token."
                 : "TMDB answered with no rows. Check the connection, or try again in a moment.")
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.muted)
            Button("Retry") {
                Task { await model.loadCinemaHome() }
            }
            .buttonStyle(.plain)
            .foregroundColor(SumiTheme.indigo)
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.vertical, 40)
    }
}
