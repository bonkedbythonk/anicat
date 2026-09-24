import SwiftUI

/// The Library: the AniList list, one status bucket at a time.
///
/// Poster grid by default because choosing what to watch is a visual
/// decision; the table is for sorting and scanning, and the choice sticks.
public struct LibraryView: View {
    let items: [MediaCard.Item]
    let isLoading: Bool
    @Binding var status: String
    @Binding var mediaType: String
    let isSignedIn: Bool
    let namespace: Namespace.ID?
    let openingSourceKey: String?
    let onSelect: (MediaCard.Item) -> Void

    @AppStorage("anicat_library_layout") private var layout: String = "grid"

    public init(
        items: [MediaCard.Item],
        isLoading: Bool,
        status: Binding<String>,
        mediaType: Binding<String>,
        isSignedIn: Bool,
        namespace: Namespace.ID? = nil,
        openingSourceKey: String? = nil,
        onSelect: @escaping (MediaCard.Item) -> Void
    ) {
        self.items = items
        self.isLoading = isLoading
        self._status = status
        self._mediaType = mediaType
        self.isSignedIn = isSignedIn
        self.namespace = namespace
        self.openingSourceKey = openingSourceKey
        self.onSelect = onSelect
    }

    /// The label changes with the type — a manga list is "Reading", not
    /// "Watching" — but the AniList status behind it is the same value.
    private var tabs: [(key: String, label: String)] {
        let manga = mediaType == "MANGA"
        return [
            ("CURRENT", manga ? "Reading" : "Watching"),
            ("REPEATING", manga ? "Rereading" : "Rewatching"),
            ("COMPLETED", "Completed"),
            ("PLANNING", "Planning"),
            ("PAUSED", "Paused"),
            ("DROPPED", "Dropped"),
        ]
    }

    /// The count and first id are the half that matters: they change when the
    /// reload lands, which is the moment the new cards have to fade in on.
    /// Keying the animation on `status` alone spent it on the tap, hundreds of
    /// milliseconds before the items moved, and the new cards then arrived
    /// with nothing left to animate them.
    private var contentKey: String {
        "\(mediaType)/\(status)/\(items.count)/\(items.first?.id ?? -1)"
    }

    public var body: some View {
        #if os(macOS)
        // Outside `SumiPage`: that page is a vertical `ScrollView`, and a
        // `Table` inside one has no height of its own and collapses to its
        // header. Here the table takes the rest of the window and scrolls
        // itself, inside the page's own insets.
        if isSignedIn && !items.isEmpty && layout != "grid" {
            GeometryReader { viewport in
            VStack(alignment: .leading, spacing: 20) {
                pageHeader
                LibraryTable(items: items, onSelect: onSelect)
                    .opacity(isLoading ? 0.5 : 1)
                    .animation(.snappy, value: isLoading)
            }
            .padding(.horizontal, SumiPage<EmptyView>.horizontalInset)
            .padding(.top, 40)
            .frame(maxWidth: SumiContentWidth.forAvailable(viewport.size.width), maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(SumiTheme.background)
        } else {
            scrollingPage
        }
        #else
        scrollingPage
        #endif
    }

    @ViewBuilder
    private var pageHeader: some View {
        SumiPageHeader(
            title: "Library",
            subtitle: "\(items.count) \(mediaType == "MANGA" ? "manga" : "anime") · \(layout)"
        ) {
            HStack(spacing: 12) {
                SumiSegmentedControl(
                    options: [("ANIME", "Anime"), ("MANGA", "Manga")],
                    selection: $mediaType
                )
                SumiSegmentedControl(
                    options: [("grid", "Grid"), ("table", "Table")],
                    selection: $layout
                )
            }
        }

        SumiTabBar(tabs: tabs, selection: $status)
    }

    private var scrollingPage: some View {
        SumiPage {
            pageHeader

            Group {
                if !isSignedIn {
                    SumiEmptyState(
                        headline: "Not signed in",
                        detail: "Connect AniList in Settings and your lists appear here."
                    )
                } else if isLoading && items.isEmpty {
                    LibrarySkeleton()
                } else if items.isEmpty {
                    SumiEmptyState(
                        headline: "This list is empty",
                        detail: "Search for \(mediaType.lowercased()) and add them to your list."
                    )
                } else if layout == "grid" {
                    SumiPosterGrid(
                        items: items,
                        namespace: namespace,
                        openingSourceKey: openingSourceKey,
                        shelfKey: "library",
                        onSelect: onSelect
                    )
                    .opacity(isLoading ? 0.5 : 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    LibraryTable(items: items, onSelect: onSelect)
                        .opacity(isLoading ? 0.5 : 1)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.snappy, value: isLoading)
            .animation(.smooth, value: status)
            .animation(.smooth(duration: 0.3), value: contentKey)
            .animation(.smooth, value: layout)
        }
    }
}

#if os(macOS)
/// `score` and `progress` are optional and `Optional` is not `Comparable`,
/// so `KeyPathComparator` cannot sort on them directly. Progress sorts by
/// count, not fraction: an airing title has no total to divide by.
fileprivate extension MediaCard.Item {
    var progressSortKey: Int { progress ?? 0 }
    var scoreSortKey: Int { score ?? -1 }
}

private struct LibraryTable: View {
    let items: [MediaCard.Item]
    let onSelect: (MediaCard.Item) -> Void

    /// Empty until a header is clicked, so the list first shows in the order
    /// AniList returns it: most recently updated first.
    @State private var sortOrder: [KeyPathComparator<MediaCard.Item>] = []
    @State private var selection: MediaCard.Item.ID?

    private var rows: [MediaCard.Item] {
        sortOrder.isEmpty ? items : items.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title, comparator: .localizedStandard) { item in
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
            }
            TableColumn("Progress", value: \.progressSortKey) { item in
                Text("\(item.progress ?? 0) / \(item.totalEpisodesOrChapters.map(String.init) ?? "?")")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }
            .width(min: 80, ideal: 110, max: 140)
            TableColumn("Score", value: \.scoreSortKey) { item in
                Text(item.score.map { "\($0)%" } ?? "—")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }
            .width(min: 60, ideal: 80, max: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .tint(SumiTheme.indigo)
        // The button rows this replaced opened on a single click; a table's
        // primary action is a double-click. Selection opens instead, and is
        // cleared at once: left set, a second click on the same row changes
        // nothing and opens nothing.
        .onChange(of: selection) { _, id in
            guard let id, let item = items.first(where: { $0.id == id }) else { return }
            selection = nil
            onSelect(item)
        }
    }
}
#else
private struct LibraryTable: View {
    let items: [MediaCard.Item]
    let onSelect: (MediaCard.Item) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                header("Title", width: nil)
                header("Progress", width: 120)
                header("Score", width: 80)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(Rectangle().fill(SumiTheme.border).frame(height: 1), alignment: .bottom)

            LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 0) {
                        Text(item.title)
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(item.progress ?? 0) / \(item.totalEpisodesOrChapters.map(String.init) ?? "?")")
                            .sumiTabularMono(size: 11.5)
                            .foregroundColor(SumiTheme.muted)
                            .frame(width: 120, alignment: .leading)
                        Text(item.score.map { "\($0)%" } ?? "—")
                            .sumiTabularMono(size: 11.5)
                            .foregroundColor(SumiTheme.muted)
                            .frame(width: 80, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)

                if index < items.count - 1 {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                }
            }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    private func header(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .sumiTabularMono(size: 11.5, weight: .medium)
            .foregroundColor(SumiTheme.muted)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
#endif
