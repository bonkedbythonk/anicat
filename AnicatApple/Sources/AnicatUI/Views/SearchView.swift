import SwiftUI

public struct SearchView: View {
    @Binding public var searchText: String
    public let results: [MediaCard.Item]
    public let isLoading: Bool
    public let onSearchCommit: (String) -> Void
    public let onSelectMedia: (MediaCard.Item) -> Void

    public init(
        searchText: Binding<String>,
        results: [MediaCard.Item],
        isLoading: Bool = false,
        onSearchCommit: @escaping (String) -> Void = { _ in },
        onSelectMedia: @escaping (MediaCard.Item) -> Void = { _ in }
    ) {
        self._searchText = searchText
        self.results = results
        self.isLoading = isLoading
        self.onSearchCommit = onSearchCommit
        self.onSelectMedia = onSelectMedia
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                // Header & Search Input
                VStack(alignment: .leading, spacing: 12) {
                    Text("Search")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(SumiTheme.foreground)

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundColor(SumiTheme.muted)

                        TextField("Search anime, manga, studios, genres...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundColor(SumiTheme.foreground)
                            .onSubmit {
                                onSearchCommit(searchText)
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 24)

                // Results Count
                if !results.isEmpty {
                    HStack {
                        Text("\(results.count) RESULTS")
                            .sumiTabularMono(size: 11, weight: .semibold)
                            .foregroundColor(SumiTheme.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 24)

                    // Responsive Grid
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)], spacing: 20) {
                        ForEach(results) { item in
                            MediaCard(item: item) {
                                onSelectMedia(item)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
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
            .padding(.vertical, 24)
        }
        .background(SumiTheme.background)
    }
}
