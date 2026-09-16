#if os(iOS)
import SwiftUI

/// Manga and light novels on the phone, under one tab.
///
/// A segment rather than two tabs: the two shelves are the same shape
/// (Continue, Reading, Planning, Trending) over the same AniList list, and
/// the header already teaches the segment for Anime / Films & TV. Same
/// loaders as the Mac's `ReadingView`; this is the phone chrome over them.
struct PhoneReadTab: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool

    enum Kind: String, CaseIterable, Identifiable {
        case manga = "Manga"
        case novels = "Light Novels"
        var id: String { rawValue }
    }

    @AppStorage("anicat_read_kind") private var kindRaw = Kind.manga.rawValue
    private var kind: Kind { Kind(rawValue: kindRaw) ?? .manga }

    private var reading: [MediaCard.Item] { kind == .manga ? model.mangaReading : model.novelReading }
    private var planning: [MediaCard.Item] { kind == .manga ? model.mangaPlanning : model.novelPlanning }
    private var trending: [MediaCard.Item] { kind == .manga ? model.mangaTrending : model.novelTrending }

    /// The Mac derives its resume queue the same way: a reading-list entry
    /// with progress is one to pick back up, and there is no separate
    /// "continue" array in the model.
    private var continueReading: [MediaCard.Item] {
        reading.filter { ($0.progress ?? 0) > 0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    // Title then segment, the same two rows `TabHeader`
                    // draws for Anime / Films & TV, with the segment
                    // pulled up into the header's bottom padding.
                    VStack(alignment: .leading, spacing: 0) {
                        TabHeader(title: "Read", model: nil) { EmptyView() }
                        Picker("", selection: $kindRaw) {
                            ForEach(Kind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                        .padding(.horizontal, 16)
                    }

                    if kind == .novels {
                        novelEntry
                    }

                    if !model.isSignedIn, reading.isEmpty, trending.isEmpty {
                        EmptyHint(
                            title: "Nothing to read yet",
                            detail: "Connect AniList in Settings to see your reading list, or search for a title."
                        )
                    } else {
                        if !continueReading.isEmpty {
                            ContinueReadingRow(items: continueReading, onOpen: open)
                        }
                        PosterShelf(title: "Reading", items: reading, onOpen: open)
                        PosterShelf(title: "Planning", items: planning, onOpen: open)
                        PosterShelf(title: "Trending", items: trending, onOpen: open)
                        if reading.isEmpty, planning.isEmpty, trending.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 48)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(SumiTheme.background)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.loadReadingShelves() }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
        .task {
            if model.mangaTrending.isEmpty, model.novelTrending.isEmpty {
                await model.loadReadingShelves()
            }
        }
    }

    private func open(_ item: MediaCard.Item) {
        showDetail = true
        Task {
            await model.openDetail(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: true)
        }
    }

    /// The two ways into the novel reader that are not a title: a pasted
    /// Syosetu link, and the last thing read. Both open the reader's own
    /// entry screen, which carries the URL field and the resume button.
    @ViewBuilder
    private var novelEntry: some View {
        HStack(spacing: 10) {
            Button {
                model.openNovelReaderEntry()
            } label: {
                Label("Open a Syosetu link", systemImage: "link")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SumiTheme.foreground)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(SumiTheme.card, in: Capsule())
            }
            .buttonStyle(.plain)
            if let last = NovelPreferences.lastNovel() {
                Button {
                    if last.source == AppModel.NovelSource.lnori.rawValue {
                        model.openLightNovelVolume(bookURL: last.url, title: last.title, catalogId: last.catalogId)
                    } else {
                        model.openSyosetuReader(url: last.url)
                    }
                } label: {
                    Label("Continue \(last.title)", systemImage: "arrow.right")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(SumiTheme.background)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(SumiTheme.indigo, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// The same three-across card the Up Next tab uses for episodes, with the
/// chapter count where the episode would be.
private struct ContinueReadingRow: View {
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Continue Reading")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        Button { onOpen(item) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottom) {
                                    CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 300) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        SumiTheme.card
                                    }
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    .clipped()
                                    if let total = item.totalEpisodesOrChapters, total > 0, let progress = item.progress {
                                        GeometryReader { geo in
                                            Rectangle()
                                                .fill(SumiTheme.indigo)
                                                .frame(width: geo.size.width * min(1, Double(progress) / Double(total)), height: 3)
                                                .frame(maxHeight: .infinity, alignment: .bottom)
                                        }
                                        .frame(height: 3)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(item.title)
                                    .font(.sumiHeading(size: 13, weight: .medium))
                                    .foregroundStyle(SumiTheme.foreground)
                                    .lineLimit(1)
                                Text("CH \((item.progress ?? 0) + 1)\(item.totalEpisodesOrChapters.map { " OF \($0)" } ?? "")")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(SumiTheme.muted)
                            }
                            .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
#endif
