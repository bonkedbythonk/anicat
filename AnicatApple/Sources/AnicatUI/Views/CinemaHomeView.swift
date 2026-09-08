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
        case comingSoon
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
        case .comingSoon:
            return model.cinemaShelves.filter { $0.id == "upcoming_movies" || $0.id == "airing_series" }
        case .home, .search, .watching:
            return model.cinemaShelves
        }
    }

    @FocusState private var searchFocused: Bool

    private var results: [MediaCard.Item] { model.cinemaSearchResults }
    private var isSearching: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                searchField

                if isSearching {
                    resultsGrid
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
            if page == .watching { await model.loadCinemaLibrary() }
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
        }
    }

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
            namespace: model.openingDetailSourceKey == key ? namespace : nil
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

    /// Everything with a stored position, newest first. Local only: a film
    /// has no list entry anywhere, so this is the registry and nothing else.
    @ViewBuilder
    private var watching: some View {
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
