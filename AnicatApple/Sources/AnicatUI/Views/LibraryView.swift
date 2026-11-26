#if os(macOS)
import SwiftUI

/// The Library: the AniList list, one status bucket at a time.
///
/// Poster grid by default because choosing what to watch is a visual
/// decision; the list is for scanning, and the choice sticks.
public struct LibraryView: View {
    let items: [MediaCard.Item]
    let isLoading: Bool
    @Binding var status: String
    @Binding var mediaType: String
    let isSignedIn: Bool
    let namespace: Namespace.ID?
    let openingSourceKey: String?
    let onSelect: (MediaCard.Item) -> Void

    /// "table" is the stored value for the list, kept from when the list was
    /// a `Table`: renamed, a saved preference would match neither word and
    /// the toggle would show nothing chosen.
    @AppStorage("anicat_library_layout") private var layout: String = "grid"
    @State private var sort: SortKey = .updated

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

    /// Replaces the `Table`'s header sort, so it applies to the grid too.
    /// "Last updated" is no sort at all: AniList returns the list most
    /// recently updated first.
    fileprivate enum SortKey: String, CaseIterable {
        case updated, title, progress, score

        var label: String {
            switch self {
            case .updated: "Last updated"
            case .title: "Title"
            case .progress: "Progress"
            case .score: "Score"
            }
        }
    }

    private var isManga: Bool { mediaType == "MANGA" }

    /// The label changes with the type — a manga list is "Reading", not
    /// "Watching" — but the AniList status behind it is the same value.
    private var tabs: [(key: String, label: String)] {
        [
            ("CURRENT", isManga ? "Reading" : "Watching"),
            ("PLANNING", "Planning"),
            ("COMPLETED", "Completed"),
            ("PAUSED", "Paused"),
            ("DROPPED", "Dropped"),
            ("REPEATING", isManga ? "Rereading" : "Rewatching"),
        ]
    }

    private var sortedItems: [MediaCard.Item] {
        switch sort {
        case .updated: items
        case .title: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        // By count, not fraction: an airing title has no total to divide by.
        case .progress: items.sorted { ($0.progress ?? 0) > ($1.progress ?? 0) }
        case .score: items.sorted { ($0.score ?? -1) > ($1.score ?? -1) }
        }
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
        SumiPage {
            SumiPageHeader(
                title: "Library",
                subtitle: "\(items.count) \(isManga ? "manga" : "anime")"
            ) {
                SumiSegmentedControl(
                    options: [("ANIME", "Anime"), ("MANGA", "Manga")],
                    selection: $mediaType
                )
            }

            tabRow

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
                        detail: "Search for \(mediaType.lowercased()) and add them to your list.",
                        art: "empty"
                    )
                } else if layout == "grid" {
                    SumiPosterGrid(
                        items: sortedItems,
                        namespace: namespace,
                        openingSourceKey: openingSourceKey,
                        shelfKey: "library",
                        onSelect: onSelect
                    )
                    .opacity(isLoading ? 0.5 : 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    LibraryList(items: sortedItems, isManga: isManga, onSelect: onSelect)
                        .opacity(isLoading ? 0.5 : 1)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.snappy, value: isLoading)
            .animation(.smooth, value: status)
            .animation(.smooth(duration: 0.3), value: contentKey)
            .animation(.smooth, value: layout)
            .animation(.smooth, value: sort)
        }
    }

    /// Status words on the left, sort and layout on the right, over one
    /// hairline. Six tabs and both controls measure about 770pt; in a window
    /// narrower than that one row pushed the controls past the edge, so they
    /// drop to a line of their own instead.
    private var tabRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                SumiTabBar(tabs: tabs, selection: $status)
                Spacer(minLength: 16)
                controls
            }
            VStack(alignment: .leading, spacing: 8) {
                SumiTabBar(tabs: tabs, selection: $status)
                controls
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            sortMenu
            SumiSegmentedControl(
                options: [("grid", "Grid"), ("table", "List")],
                selection: $layout
            )
        }
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortKey.allCases, id: \.self) { key in
                Button {
                    sort = key
                } label: {
                    HStack {
                        Text(key.label)
                        if key == sort {
                            Image(anicat: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                // One `Text`: under `.borderlessButton` the menu is an
                // NSPopUpButton, which draws only the first `Text` of its
                // label, so the chosen sort as a sibling never showed.
                (Text("Sort: ").foregroundColor(SumiTheme.muted)
                    + Text(sort.label).foregroundColor(SumiTheme.foreground))
                Image(anicat: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(SumiTheme.muted)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(SumiTheme.card)
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
            .overlay(
                SumiRect(cornerRadius: SumiTheme.radiusSm)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// One row per title: cover, title, progress, score, split by hairlines.
/// Opens on a single click, as the grid does; the `Table` it replaced opened
/// on selection and had to clear it at once so a second click still worked.
private struct LibraryList: View {
    let items: [MediaCard.Item]
    let isManga: Bool
    let onSelect: (MediaCard.Item) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 14) {
                        // 36pt wide, so 120px covers Retina without decoding
                        // a poster no row draws.
                        CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 120) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                        .frame(width: 36, height: 54)
                        .background(SumiTheme.card)
                        .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
                        .overlay(
                            SumiRect(cornerRadius: SumiTheme.radiusSm)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )

                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        progress(item)
                            .frame(width: 200, alignment: .leading)

                        Text(item.score.map { "\($0)%" } ?? "—")
                            .sumiTabularMono(size: 11.5)
                            .foregroundColor(SumiTheme.muted)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                }
            }
        }
    }

    private func progress(_ item: MediaCard.Item) -> some View {
        let unit = isManga ? "Ch." : "Ep"
        let done = item.progress ?? 0
        return HStack(spacing: 6) {
            if done > 0 {
                Text(item.totalEpisodesOrChapters.map { "\(unit) \(done) / \($0)" } ?? "\(unit) \(done)")
            } else if let total = item.totalEpisodesOrChapters {
                Text("\(total) \(isManga ? "chapters" : "episodes")")
            } else {
                Text("—")
            }
            if item.hasNewEpisode {
                Text("\(unit) \(done + 1) out")
                    .foregroundColor(SumiTheme.indigo)
                    .fontWeight(.semibold)
            }
        }
        .sumiTabularMono(size: 11.5)
        .foregroundColor(SumiTheme.muted)
        .lineLimit(1)
    }
}
#endif
