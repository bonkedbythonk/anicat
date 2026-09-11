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
        /// Not in the rail since 6.0.2. Kept so the phone, which still has
        /// an Up Next tab in cinema, can draw the queue over the shelves.
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

    /// Cinema's search lives on the Search section, the way the anime rail's
    /// does. Drawn on all five sections it was the same field five times,
    /// each with its own idea of what the page below it was showing.
    private var showsSearchField: Bool { page == .search }

    @FocusState private var searchFocused: Bool

    enum WatchingTab: Hashable { case continueWatching, list }
    @State private var watchingTab: WatchingTab = .continueWatching

    private var results: [MediaCard.Item] { model.cinemaSearchResults }
    private var isSearching: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // See RootView: measured outside the scroll view, because a reader
        // inside one reports the content width rather than the viewport.
        GeometryReader { viewport in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if showsSearchField { searchField }

                if page == .search {
                    if !isSearching { filterRow }
                    resultsGrid
                } else if page == .films || page == .series {
                    ForEach(shelves) { shelf in
                        shelfRow(shelf)
                    }
                    if !model.cinemaSearchResults.isEmpty {
                        resultsGrid
                    }
                } else if page == .home, !model.cinemaUpNext.isEmpty {
                    upNext(title: "Up Next")
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
            .frame(maxWidth: SumiContentWidth.forAvailable(viewport.size.width), alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            if model.cinemaShelves.isEmpty { await model.loadCinemaHome() }
            if page == .watching || page == .home { await model.loadCinemaLibrary() }
            // Each section refills the grid on arrival, unconditionally rather
            // than "if it is empty": one array holds both the keyword results
            // and the discover browse, so a search for "Dune" was still
            // sitting under Films until something else replaced it. TMDB's
            // responses are cached, so re-asking costs a cache read.
            if page == .films || page == .series {
                // Sets the kind and browses in one step -- see
                // `openCinemaBrowse` for why this is not `applyCinemaFilter`.
                await model.openCinemaBrowse(isSeries: page == .series)
            } else if page == .search {
                if model.cinemaGenres.isEmpty { await model.loadCinemaGenres() }
                await model.searchCinema(model.searchQuery)
            }
            if focusSearchOnAppear { searchFocused = true }
        }
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

            // The next page fetches itself when the foot of the grid comes
            // into view, instead of asking to be asked. A "Load more" button
            // is a click that only ever has one answer, and the grid it sits
            // under is `LazyVGrid` -- the rows below the viewport are not
            // built until they are scrolled to anyway, so the page boundary
            // was visible for no reason.
            if model.cinemaSearchHasMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more")
                        .sumiTabularMono(size: 11)
                        .foregroundColor(SumiTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
                // Keyed on the page number: `task(id:)` re-runs when the id
                // changes, so each arriving page arms the next fetch, and a
                // row that scrolls away and back does not fetch twice.
                .task(id: model.cinemaSearchPage) {
                    guard !model.isLoadingMoreCinema else { return }
                    await model.searchCinema(
                        model.searchQuery,
                        page: model.cinemaSearchPage + 1,
                        append: true
                    )
                }
            }
        }
    }

    /// Films or series, a genre, a year and a sort -- TMDB's `/discover`,
    /// which is the only way to ask for "action films from 1999". Shown on
    /// the Search section with an empty field: with text in it the keyword
    /// search runs instead, and TMDB ignores the filters there rather than
    /// combining them.
    private var filterRow: some View {
        // `SumiSegmentedControl` and `SumiFilterDropdown`, not bare `Picker`s.
        // A plain Picker renders as AppKit's own segmented control and pop-up
        // buttons -- system blue, system corner radius, system font -- which
        // is why this row read as a different app's from the shelves under it.
        // The anime side's filters have been these controls since they
        // existed; cinema was the one screen still on the defaults.
        HStack(spacing: 10) {
            // The kind segment lives on Search alone: on the Films section it
            // was a control that argued with the rail, since flipping it left
            // a section titled Films showing series.
            SumiSegmentedControl(
                options: [("films", "Films"), ("series", "Series")],
                selection: Binding(
                    get: { model.cinemaFilter.isSeries ? "series" : "films" },
                    set: { next in model.applyCinemaFilter { $0.isSeries = (next == "series") } }
                )
            )

            // The dropdowns speak strings and treat "" as no filter, so the
            // ids go through as text and come back parsed.
            SumiFilterDropdown(
                label: "Genre",
                options: [("", "Any")] + model.cinemaGenres.map { (String($0.id), $0.name) },
                selected: Binding(
                    get: { model.cinemaFilter.genreId.map(String.init) ?? "" },
                    set: { next in model.applyCinemaFilter { $0.genreId = Int64(next) } }
                )
            )

            SumiFilterDropdown(
                label: "Year",
                options: [("", "Any")] + Self.years.map { (String($0), String($0)) },
                selected: Binding(
                    get: { model.cinemaFilter.year.map(String.init) ?? "" },
                    set: { next in model.applyCinemaFilter { $0.year = Int(next) } }
                )
            )

            SumiFilterDropdown(
                label: "Sort",
                options: [
                    ("popularity.desc", "Popular"),
                    ("vote_average.desc", "Top rated"),
                    ("primary_release_date.desc", "Newest"),
                ],
                selected: Binding(
                    get: { model.cinemaFilter.sort },
                    set: { next in model.applyCinemaFilter { $0.sort = next.isEmpty ? "popularity.desc" : next } }
                )
            )

            Spacer(minLength: 0)
        }
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
                    .font(.sumiHeading(size: 15, weight: .semibold))
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
                        card(item, shelf: shelf.id)
                            .frame(width: 180)
                            .sumiShelfEdge()
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
    private func upNext(title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(title)
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
                onSelect: { entry in
                    let catalog = model.cinemaCatalog(forId: entry.id)
                    // No source key: this queue's rows carry no namespace,
                    // so naming one only tells the rest of the app a morph
                    // is running when none is.
                    model.openingDetailSourceKey = nil
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
                },
                onRemove: { entry in
                    Task { await model.removeFromCinemaContinueWatching(id: entry.id) }
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
            SumiSegmentedControl(
                options: [("continue", "Continue"), ("list", "Watchlist")],
                selection: Binding(
                    get: { watchingTab == .list ? "list" : "continue" },
                    set: { watchingTab = ($0 == "list") ? .list : .continueWatching }
                )
            )

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
            // The same tab bar the Library's status filter uses: four
            // statuses is a row of words, not a dropdown to open.
            SumiTabBar(
                tabs: [
                    ("PLANNING", "Planning"),
                    ("CURRENT", "Watching"),
                    ("COMPLETED", "Completed"),
                    ("DROPPED", "Dropped"),
                ],
                selection: Binding(
                    get: { model.cinemaWatchlistFilter },
                    set: { next in
                        model.cinemaWatchlistFilter = next
                        Task { await model.loadCinemaWatchlist() }
                    }
                )
            )

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
            VStack(alignment: .leading, spacing: 24) {
                // The resume rows first: one press picks a film up where it
                // stopped. This queue headed the cinema Home until that page
                // went; the grid under it is every title with a position.
                if !model.cinemaUpNext.isEmpty {
                    upNext(title: "Pick up where you left off")
                }
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
                                // Right-click, like the Finder: the card has no
                                // spare corner for a control, and a hover "x"
                                // next to the open chevron was two targets on
                                // one poster.
                                .contextMenu {
                                    Button("Remove from Continue Watching") {
                                        Task { await model.removeFromCinemaContinueWatching(id: item.id) }
                                    }
                                }
                        }
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
