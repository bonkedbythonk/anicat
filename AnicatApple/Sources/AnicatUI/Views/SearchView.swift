import SwiftUI

public struct SearchView: View {
    @Binding public var searchText: String
    public let results: [MediaCard.Item]
    public let isLoading: Bool
    public let onSearchCommit: (String, Bool) -> Void
    public let onSelectMedia: (MediaCard.Item) -> Void

    @State private var searchType: String = "ANIME"

    public init(
        searchText: Binding<String>,
        results: [MediaCard.Item],
        isLoading: Bool = false,
        onSearchCommit: @escaping (String, Bool) -> Void = { _, _ in },
        onSelectMedia: @escaping (MediaCard.Item) -> Void = { _ in }
    ) {
        self._searchText = searchText
        self.results = results
        self.isLoading = isLoading
        self.onSearchCommit = onSearchCommit
        self.onSelectMedia = onSelectMedia
    }

    public init(
        searchText: Binding<String>,
        results: [MediaCard.Item],
        isLoading: Bool = false,
        onSearchCommit: @escaping (String) -> Void,
        onSelectMedia: @escaping (MediaCard.Item) -> Void = { _ in }
    ) {
        self._searchText = searchText
        self.results = results
        self.isLoading = isLoading
        self.onSearchCommit = { query, _ in onSearchCommit(query) }
        self.onSelectMedia = onSelectMedia
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
                            options: [("ANIME", "Anime"), ("MANGA", "Manga")],
                            selection: $searchType
                        )
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundColor(SumiTheme.muted)

                        TextField(searchType == "MANGA" ? "Search manga, authors, genres..." : "Search anime, studios, genres...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundColor(SumiTheme.foreground)
                            .onSubmit {
                                onSearchCommit(searchText, searchType == "MANGA")
                            }

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(SumiTheme.muted)
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
                }
                .onChange(of: searchType) { _, next in
                    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onSearchCommit(trimmed, next == "MANGA")
                    }
                }
                .padding(.horizontal, 40)

                // Results Count
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
                        ForEach(results) { item in
                            MediaCard(item: item) {
                                onSelectMedia(item)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                } else if !searchText.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 36))
                            .foregroundColor(SumiTheme.muted.opacity(0.4))
                        Text("No titles found for \"\(searchText)\"")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SumiTheme.background)
    }
}
