import SwiftUI
import AnicatCoreKit

public struct SearchView: View {
    @Binding public var searchText: String
    public let results: [MediaCard.Item]
    public let discoverItems: [MediaCard.Item]
    public let isLoading: Bool
    /// Query, the AniList media type ("ANIME"/"MANGA"/"NOVEL"), and the
    /// active filters — the search view owns filter state since it's the
    /// only screen that exposes it, and hands the resolved value up rather
    /// than making the caller peek at private @State.
    public let onSearchCommit: (String, String, SearchFilters) -> Void
    public let onSelectMedia: (MediaCard.Item) -> Void
    public let onLoadDiscover: () -> Void
    public let onShuffle: () -> Void
    public var hasMorePages: Bool = true
    public var isLoadingMore: Bool = false
    public var onLoadMore: (String, String, SearchFilters) -> Void = { _, _, _ in }

    @State private var searchType: String = "ANIME"

    // Filters. Empty string means "Any" / no filter — kept as String state
    // (rather than optionals) because SumiFilterDropdown binds to a plain
    // String, and every value here maps straight onto an AniList enum or a
    // literal year/score the backend already validates.
    @State private var genreFilter: String = ""
    @State private var yearFilter: String = ""
    @State private var minScoreFilter: String = ""
    @State private var statusFilter: String = ""
    @State private var sortFilter: String = ""

    public init(
        searchText: Binding<String>,
        results: [MediaCard.Item],
        discoverItems: [MediaCard.Item] = [],
        isLoading: Bool = false,
        onSearchCommit: @escaping (String, String, SearchFilters) -> Void = { _, _, _ in },
        onSelectMedia: @escaping (MediaCard.Item) -> Void = { _ in },
        onLoadDiscover: @escaping () -> Void = {},
        onShuffle: @escaping () -> Void = {},
        hasMorePages: Bool = true,
        isLoadingMore: Bool = false,
        onLoadMore: @escaping (String, String, SearchFilters) -> Void = { _, _, _ in }
    ) {
        self._searchText = searchText
        self.results = results
        self.discoverItems = discoverItems
        self.isLoading = isLoading
        self.onSearchCommit = onSearchCommit
        self.onSelectMedia = onSelectMedia
        self.onLoadDiscover = onLoadDiscover
        self.onShuffle = onShuffle
        self.hasMorePages = hasMorePages
        self.isLoadingMore = isLoadingMore
        self.onLoadMore = onLoadMore
    }

    private var searchPlaceholder: String {
        switch searchType {
        case "MANGA": return "Search manga, authors, genres..."
        case "NOVEL": return "Search light novels, authors, genres..."
        default: return "Search anime, studios, genres..."
        }
    }

    private static let genreOptions: [(value: String, label: String)] = [
        ("", "Any"), ("Action", "Action"), ("Adventure", "Adventure"), ("Comedy", "Comedy"),
        ("Drama", "Drama"), ("Ecchi", "Ecchi"), ("Fantasy", "Fantasy"), ("Horror", "Horror"),
        ("Mahou Shoujo", "Mahou Shoujo"), ("Mecha", "Mecha"), ("Music", "Music"), ("Mystery", "Mystery"),
        ("Psychological", "Psychological"), ("Romance", "Romance"), ("Sci-Fi", "Sci-Fi"),
        ("Slice of Life", "Slice of Life"), ("Sports", "Sports"), ("Supernatural", "Supernatural"),
        ("Thriller", "Thriller")
    ]

    private static var yearOptions: [(value: String, label: String)] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return [("", "Any")] + (1970...currentYear).reversed().map { (String($0), String($0)) }
    }

    private static let scoreOptions: [(value: String, label: String)] = [
        ("", "Any"), ("90", "90+"), ("80", "80+"), ("70", "70+"), ("60", "60+"), ("50", "50+")
    ]

    private static let statusOptions: [(value: String, label: String)] = [
        ("", "Any"), ("RELEASING", "Releasing"), ("FINISHED", "Finished"),
        ("NOT_YET_RELEASED", "Not Yet Released"), ("HIATUS", "Hiatus"), ("CANCELLED", "Cancelled")
    ]

    private static let sortOptions: [(value: String, label: String)] = [
        ("", "Popularity"), ("SCORE_DESC", "Score"), ("TRENDING_DESC", "Trending"),
        ("START_DATE_DESC", "Newest"), ("TITLE_ROMAJI", "Title A-Z")
    ]

    private var activeFilters: SearchFilters {
        SearchFilters(
            genre: genreFilter.isEmpty ? nil : genreFilter,
            year: Int32(yearFilter),
            minScore: Int32(minScoreFilter),
            status: statusFilter.isEmpty ? nil : statusFilter,
            sort: sortFilter.isEmpty ? nil : sortFilter
        )
    }

    private var hasActiveFilters: Bool {
        !genreFilter.isEmpty || !yearFilter.isEmpty || !minScoreFilter.isEmpty || !statusFilter.isEmpty || !sortFilter.isEmpty
    }

    private func commitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank query with a filter set is a legitimate browse ("show me
        // Action anime"), not a no-op — AniList's `Page.media` accepts a
        // null `search` and just returns a filtered, popularity-sorted list.
        // Requiring text here is what made picking a genre alone do nothing.
        guard !trimmed.isEmpty || hasActiveFilters else { return }
        onSearchCommit(trimmed, searchType, activeFilters)
    }

    private func loadMore() {
        guard hasMorePages, !isLoadingMore else { return }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasActiveFilters else { return }
        onLoadMore(trimmed, searchType, activeFilters)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                // Header & Search Input
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        Text("Search & Browse")
                            .font(.system(size: 19, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundColor(SumiTheme.foreground)

                        Spacer()

                        SumiSegmentedControl(
                            options: [("ANIME", "Anime"), ("MANGA", "Manga"), ("NOVEL", "Novels")],
                            selection: $searchType
                        )

                        SumiOutlineButton("Shuffle", systemImage: "shuffle", action: onShuffle)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundColor(SumiTheme.muted)

                        TextField(searchPlaceholder, text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundColor(SumiTheme.foreground)
                            .onSubmit {
                                commitSearch()
                            }

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(SumiTheme.muted)
                                    .padding(4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(SumiTheme.indigo)
                        }
                    }
                    // `bg-transparent border border-border rounded-lg`: the
                    // field is a hairline over the page ground, not a filled
                    // surface. Filling it made the one input on the page read
                    // as a card and pulled more weight than the results.
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )

                    // Filter row. Always visible rather than behind a
                    // disclosure toggle — five dropdowns fit on one line at
                    // the page's own 1100pt cap, and a hidden panel is easy
                    // to forget is holding a filter from an earlier search.
                    HStack(spacing: 8) {
                        SumiFilterDropdown(label: "Genre", options: Self.genreOptions, selected: $genreFilter)
                        SumiFilterDropdown(label: "Year", options: Self.yearOptions, selected: $yearFilter)
                        SumiFilterDropdown(label: "Score", options: Self.scoreOptions, selected: $minScoreFilter)
                        SumiFilterDropdown(label: "Status", options: Self.statusOptions, selected: $statusFilter)
                        SumiFilterDropdown(label: "Sort", options: Self.sortOptions, selected: $sortFilter)

                        if hasActiveFilters {
                            Button {
                                withAnimation(.snappy) {
                                    genreFilter = ""
                                    yearFilter = ""
                                    minScoreFilter = ""
                                    statusFilter = ""
                                    sortFilter = ""
                                }
                            } label: {
                                Text("Clear filters")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(SumiTheme.muted)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }

                        Spacer()
                    }
                    .animation(.snappy, value: hasActiveFilters)
                }
                .onChange(of: searchType) { _, _ in commitSearch() }
                // One handler on the combined value rather than five on the
                // individual @State vars — "Clear filters" sets all five at
                // once, and five separate onChange handlers would each fire
                // their own redundant search for that single tap.
                .onChange(of: activeFilters) { _, _ in commitSearch() }
                // `.task(id:)` cancels the previous debounce automatically
                // when `searchText` changes again, so only the last keystroke
                // in a burst actually fires a search. Without this, typing
                // did nothing until Return was pressed — the only visible
                // feedback was the (also broken, see SumiFilterDropdown) filter
                // row, so the whole search page read as unresponsive.
                .task(id: searchText) {
                    guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    commitSearch()
                }
                .padding(.horizontal, 40)

                // Discover Section — trending, unfiltered. Shown only when
                // there's neither a typed query nor an active filter; a
                // filter alone now drives a real (filtered) search via
                // `commitSearch`, so leaving this condition at `searchText.
                // isEmpty` used to show trending nonsense right underneath a
                // picked genre that silently did nothing.
                if searchText.isEmpty && !hasActiveFilters {
                    if !discoverItems.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Discover")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(SumiTheme.foreground)
                                Spacer()
                                Text("TRENDING")
                                    .sumiTabularMono(size: 11.5)
                                    .foregroundColor(SumiTheme.indigo)
                            }
                            .padding(.horizontal, 40)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 165, maximum: 200), spacing: 20, alignment: .top)],
                                alignment: .leading,
                                spacing: 20
                            ) {
                                ForEach(discoverItems) { item in
                                    MediaCard(item: item) {
                                        onSelectMedia(item)
                                    }
                                }
                            }
                            .padding(.horizontal, 40)
                            .opacity(isLoading ? 0.5 : 1)
                            .animation(.snappy, value: isLoading)
                        }
                    } else if isLoading {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Discover")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(SumiTheme.foreground)
                                Spacer()
                                Text("TRENDING")
                                    .sumiTabularMono(size: 11.5)
                                    .foregroundColor(SumiTheme.indigo)
                            }
                            .padding(.horizontal, 40)

                            MediaGridSkeleton(count: 12)
                                .padding(.horizontal, 40)
                        }
                    }
                }

                // Results Count
                Group {
                    if !results.isEmpty {
                        HStack {
                            Text("\(results.count) results")
                                .sumiTabularMono(size: 11.5)
                                .foregroundColor(SumiTheme.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 40)

                        // `gap-5` (20pt) both ways, five to six columns wide. The
                        // adaptive range brackets the poster width the shelves on
                        // the home page use so a card is the same size in both.
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 165, maximum: 200), spacing: 20, alignment: .top)],
                            alignment: .leading,
                            spacing: 20
                        ) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                MediaCard(item: item) {
                                    onSelectMedia(item)
                                }
                                // Firing the next page a few cards before the
                                // true end means the next row is already
                                // loading by the time the viewer scrolls to
                                // it, instead of hitting a dead stop and then
                                // a pop-in once the request lands.
                                .onAppear {
                                    if index == results.count - 6 {
                                        loadMore()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                        .opacity(isLoading ? 0.5 : 1)
                        .animation(.snappy, value: isLoading)

                        if isLoadingMore {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(SumiTheme.indigo)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    } else if isLoading {
                        MediaGridSkeleton(count: 12)
                            .padding(.horizontal, 40)
                    } else if !searchText.isEmpty || hasActiveFilters {
                        VStack(spacing: 8) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: 36))
                                .foregroundColor(SumiTheme.muted.opacity(0.4))
                            Text(searchText.isEmpty ? "No titles found" : "No titles found for \"\(searchText)\"")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .animation(.smooth, value: results.isEmpty)
            }
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SumiTheme.background)
        .onAppear { onLoadDiscover() }
    }
}
