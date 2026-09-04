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
    let onSelect: (MediaCard.Item) -> Void

    @AppStorage("anicat_library_layout") private var layout: String = "grid"

    public init(
        items: [MediaCard.Item],
        isLoading: Bool,
        status: Binding<String>,
        mediaType: Binding<String>,
        isSignedIn: Bool,
        onSelect: @escaping (MediaCard.Item) -> Void
    ) {
        self.items = items
        self.isLoading = isLoading
        self._status = status
        self._mediaType = mediaType
        self.isSignedIn = isSignedIn
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
                    SumiPosterGrid(items: items, onSelect: onSelect)
                        .opacity(isLoading ? 0.5 : 1)
                } else {
                    LibraryTable(items: items, mediaType: mediaType, onSelect: onSelect)
                        .opacity(isLoading ? 0.5 : 1)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isLoading)
            .animation(.easeOut(duration: 0.25), value: status)
            .animation(.easeOut(duration: 0.25), value: layout)
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
                .buttonStyle(.plain)

                if index < items.count - 1 {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
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
