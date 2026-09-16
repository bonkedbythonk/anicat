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

    /// Which way the cards enter, signed by the tab or type change that
    /// caused the reload. Recorded when the tab flips rather than when the
    /// items land, which works because the two are hundreds of milliseconds
    /// apart: `status`/`mediaType` set a `Task` going and only its result
    /// replaces `items`.
    @State private var entranceSlide: CGFloat = 12

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
    /// reload lands, which is the moment the entrance has to animate on.
    /// Keying the animation on `status` alone spent it on the tap, hundreds of
    /// milliseconds before the items moved, and the new cards then arrived
    /// with nothing left to animate them.
    private var contentKey: String {
        "\(mediaType)/\(status)/\(items.count)/\(items.first?.id ?? -1)"
    }

    private var cardEntrance: SumiGridEntrance {
        SumiGridEntrance(step: 0.015, cap: 12, offset: CGSize(width: entranceSlide, height: 0))
    }

    private func tabIndex(_ key: String) -> Int {
        tabs.firstIndex { $0.key == key } ?? 0
    }

    public var body: some View {
        SumiPage {
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
                        entrance: cardEntrance,
                        onSelect: onSelect
                    )
                    .opacity(isLoading ? 0.5 : 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    LibraryTable(items: items, mediaType: mediaType, onSelect: onSelect)
                        .opacity(isLoading ? 0.5 : 1)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.snappy, value: isLoading)
            .animation(.smooth, value: status)
            .animation(.smooth(duration: 0.3), value: contentKey)
            .animation(.smooth, value: layout)
        }
        .onChange(of: status) { old, new in
            entranceSlide = tabIndex(new) >= tabIndex(old) ? 12 : -12
        }
        // Its own handler rather than folding into the one above: an
        // Anime/Manga switch keeps `status`, so without this the cards enter
        // from whichever side the last *tab* change happened to set.
        .onChange(of: mediaType) { _, new in
            entranceSlide = new == "MANGA" ? 12 : -12
        }
    }
}


private struct LibraryTable: View {
    let items: [MediaCard.Item]
    let mediaType: String
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
