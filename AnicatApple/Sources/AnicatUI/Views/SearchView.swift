import SwiftUI

public struct SearchView: View {
    @Binding public var searchText: String
    public let results: [MediaCard.Item]
    public let discoverItems: [MediaCard.Item]
    public let isLoading: Bool
    /// Query, and the AniList media type: "ANIME", "MANGA", or "NOVEL".
    public let onSearchCommit: (String, String) -> Void
    public let onSelectMedia: (MediaCard.Item) -> Void
    public let onLoadDiscover: () -> Void
    public let onShuffle: () -> Void

    @State private var searchType: String = "ANIME"

    public init(
        searchText: Binding<String>,
        results: [MediaCard.Item],
        discoverItems: [MediaCard.Item] = [],
        isLoading: Bool = false,
        onSearchCommit: @escaping (String, String) -> Void = { _, _ in },
        onSelectMedia: @escaping (MediaCard.Item) -> Void = { _ in },
        onLoadDiscover: @escaping () -> Void = {},
        onShuffle: @escaping () -> Void = {}
    ) {
        self._searchText = searchText
        self.results = results
        self.discoverItems = discoverItems
        self.isLoading = isLoading
        self.onSearchCommit = onSearchCommit
        self.onSelectMedia = onSelectMedia
        self.onLoadDiscover = onLoadDiscover
        self.onShuffle = onShuffle
    }

    private var searchPlaceholder: String {
        switch searchType {
        case "MANGA": return "Search manga, authors, genres..."
        case "NOVEL": return "Search light novels, authors, genres..."
        default: return "Search anime, studios, genres..."
        }
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
                                onSearchCommit(searchText, searchType)
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
                        onSearchCommit(trimmed, next)
                    }
                }
                .padding(.horizontal, 40)

                // Discover Section (shown when search query is empty)
                if searchText.isEmpty && !discoverItems.isEmpty {
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
                    }
                }

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
        .onAppear { onLoadDiscover() }
    }
}
