import SwiftUI

/// Cinema mode's home page: a search field, and the TMDB rows beneath it.
///
/// One view for both the Up Next and Search sections while the app is in
/// cinema mode. The anime side splits them because its search carries
/// formats, genre filters, sorts and a discover grid, none of which TMDB's
/// two search endpoints take; here a query is a query, so a second screen
/// would be the same field twice.
struct CinemaHomeView: View {
    let model: AppModel
    /// Focused on arrival when the viewer got here by pressing Search rather
    /// than Home -- the section is otherwise identical, and landing on it
    /// with the caret nowhere would read as the wrong page having opened.
    let focusSearchOnAppear: Bool

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
                } else if model.cinemaShelves.isEmpty {
                    if model.isCinemaLoading {
                        MediaRowSkeleton(title: "Trending Films")
                        MediaRowSkeleton(title: "Trending Series")
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(model.cinemaShelves) { shelf in
                        shelfRow(shelf)
                    }
                }
            }
            .padding(.horizontal, SumiTheme.spaceLg)
            .padding(.vertical, 24)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            if model.cinemaShelves.isEmpty { await model.loadCinemaHome() }
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
                    card(item)
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
                        card(item).frame(width: 180)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// No `matchedGeometryEffect` namespace on a cinema card, unlike the
    /// anime shelves: the same film appears in Trending and in Popular at
    /// once, and two morph sources for one id is undefined behaviour -- the
    /// bug that lost posters and made the detail page open crookedly on the
    /// anime side. The page opens with its own fade instead.
    private func card(_ item: MediaCard.Item) -> some View {
        MediaCard(item: item) {
            Task {
                await model.openCinemaDetail(
                    catalog: item.catalog ?? .tmdbMovie,
                    id: item.id,
                    title: item.title,
                    coverURL: item.coverImageURL
                )
            }
        }
        .equatable()
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
