import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

/// The `.upNext` section: queue, week strip, Watching, and every configurable
/// discover row. Pulled out of `RootView.sectionContent` because it used to
/// be a computed property inlined into the 1198-line body — any one shelf's
/// array changing (a Watching progress tick from playback, a background
/// refreshAll updating Trending) re-evaluated every other shelf's layout
/// along with it. Own `@State` for the two sheets it owns, since neither is
/// read outside this section.
struct HomeSectionView: View {
    @Bindable var model: AppModel
    let namespace: Namespace.ID
    /// The episode-still-to-video namespace, for the Up Next shelf's Play.
    let playerNamespace: Namespace.ID
    // 5th arg is the shelf-scoped source key for the poster morph (e.g.
    // "watching:12345"), nil where there's no card to morph from.
    let onOpenDetail: (Int64, String, URL?, Bool, String?) -> Void

    @State private var showHomeCustomize = false
    /// Up Next shows four rows until asked for the rest: eight or more
    /// in-progress titles pushed the week strip and every shelf below the
    /// fold, and the first row is the one that gets played anyway.
    @State private var upNextExpanded = false
    private static let upNextCollapsedCount = 4
    @State private var showPicker = false

    /// "3 in progress · 2 new episodes" — the count of new episodes is only
    /// appended when there are any, matching HomeView.tsx.
    private var upNextSubtitle: String {
        let inProgress = model.upNextItems.count
        let new = model.upNextItems.filter(\.hasNewEpisode).count
        var out = "\(inProgress) in progress"
        if new > 0 {
            out += " · \(new) new episode\(new == 1 ? "" : "s")"
        }
        return out
    }

    var body: some View {
        // Measured out here, not inside: a reader within the scroll view
        // reports the content's width, which is the thing being sized.
        GeometryReader { viewport in
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 40) {
                // Up Next Section Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Up Next")
                                .font(.sumiHeading(size: 19, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundColor(SumiTheme.foreground)

                            if !model.upNextItems.isEmpty {
                                Text(upNextSubtitle)
                                    .sumiTabularMono(size: 11.5)
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }

                        Spacer()

                        // Words, like the detail page's secondary actions:
                        // two boxed buttons were the last boxes left on the
                        // home screen once the queue lost its frame.
                        HStack(spacing: 14) {
                            headerAction("Pick for me") { showPicker = true }
                            Rectangle().fill(SumiTheme.border).frame(width: 1, height: 14)
                            // Reorders/hides the configurable rows below.
                            // Shown even signed-out: Trending, Newly
                            // releasing and Seasonal all work without a
                            // token, only Planning needs one.
                            headerAction("Customize") { showHomeCustomize = true }
                        }
                    }

                    // Up Next Queue Container
                    if !model.upNextItems.isEmpty {
                        UpNextQueueView(
                            items: upNextExpanded ? model.upNextItems : Array(model.upNextItems.prefix(Self.upNextCollapsedCount)),
                            namespace: namespace,
                            playerNamespace: playerNamespace,
                            playerSourceKey: model.openingPlayerSourceKey,
                            onSelect: { entry in
                                onOpenDetail(entry.id, entry.title, entry.thumbnailURL, entry.unit == "CH", nil)
                            },
                            onPlay: { entry in
                                if entry.unit == "CH" {
                                    onOpenDetail(entry.id, entry.title, entry.thumbnailURL, true, nil)
                                } else {
                                    playFromShelf(
                                        model: model,
                                        catalogId: entry.id,
                                        episode: entry.nextEpisodeOrChapter,
                                        title: entry.title,
                                        coverURL: entry.thumbnailURL,
                                        morphThumbnailURL: entry.thumbnailURL
                                    )
                                }
                            }
                        )
                        if model.upNextItems.count > Self.upNextCollapsedCount {
                            Button {
                                withAnimation(.smooth(duration: 0.35)) { upNextExpanded.toggle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(upNextExpanded ? "Show fewer" : "Show all \(model.upNextItems.count)")
                                        .font(.system(size: 12.5, weight: .semibold))
                                    Image(systemName: upNextExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(SumiTheme.muted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(upNextExpanded ? "Show fewer Up Next titles" : "Show all Up Next titles")
                        }
                    } else {
                        // Mirrors HomeView.tsx: an empty queue states the absence
                        // plainly rather than leaving the "Up Next" heading over
                        // nothing. 15pt semibold headline, 13pt muted detail.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing in progress")
                                .font(.system(size: 15, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundColor(SumiTheme.foreground)
                            Text("Pick something from your library and it shows up here.")
                                .font(.system(size: 13))
                                .foregroundColor(SumiTheme.muted)
                        }
                        .padding(.horizontal, 4)
                    }
                }

                if !model.scheduleItems.filter({ $0.isWatching }).isEmpty {
                    WeekStrip(items: model.scheduleItems) { item in
                        onOpenDetail(item.id, item.title, item.coverImageURL, false, nil)
                    }
                }

                // Configurable rows, in the user's saved order; hidden ones
                // are skipped entirely rather than shown collapsed.
                ForEach(model.homeRowConfig.filter(\.visible)) { row in
                    homeDiscoverRow(id: row.id, title: row.title)
                }
            }
            // Capped so the shelves do not stretch across a whole 1512 pt
            // fullscreen, and centred: left-aligned under a 1100 cap the
            // right third of a fullscreen window was empty ("blank space on
            // the right side").
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: SumiContentWidth.forAvailable(viewport.size.width), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollLagProbe("home")
        .background(SumiTheme.background)
        .sheet(isPresented: $showHomeCustomize) {
            HomeCustomizeSheet(model: model, isPresented: $showHomeCustomize)
        }
        .sheet(isPresented: $showPicker) {
            PickerSheet(
                model: model,
                isPresented: $showPicker,
                onCommit: { item in
                    // No source card behind a modal sheet once it's
                    // dismissed, so no sourceKey — plain fade like any
                    // other non-card open.
                    onOpenDetail(item.id, item.title, item.coverImageURL, item.isManga, nil)
                }
            )
        }
        }
    }

    private func headerAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }

    /// One configurable row, by id. Skeletons preserve the shelf layout
    /// while queries are in flight, preventing sudden reflows. `id` doubles
    /// as the row's shelf key: distinct rows can show the same title at
    /// once (Watching and Trending, say), so the poster-morph source has to
    /// be scoped per-row, not just per-id — see `AppModel.openingDetailSourceKey`.
    @ViewBuilder
    private func homeDiscoverRow(id: String, title: String) -> some View {
        switch id {
        case "becauseYouWatched":
            // No skeleton: signed out the engine answers with an empty list
            // rather than an error, so a placeholder here would sit on the
            // page forever for anyone without a token.
            HomeShelf(model: model, title: title, shelfKey: "because", items: \.becauseYouWatched,
                      skeleton: .never, namespace: namespace, onOpenDetail: onOpenDetail)
        case "planning":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.planningItems,
                      requiresSignIn: true, namespace: namespace, onOpenDetail: onOpenDetail)
        case "smartPlaylist":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.smartPicks,
                      requiresSignIn: true, namespace: namespace, onOpenDetail: onOpenDetail)
        case "trending":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.trendingItems,
                      namespace: namespace, onOpenDetail: onOpenDetail)
        case "newlyReleasing":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.newlyReleasingItems,
                      namespace: namespace, onOpenDetail: onOpenDetail)
        case "seasonal":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.seasonalItems,
                      namespace: namespace, onOpenDetail: onOpenDetail)
        default:
            EmptyView()
        }
    }
}

/// One shelf, reading its own array off the model so a shelf landing
/// invalidates this row alone. Inlined in `HomeSectionView.body`, every
/// shelf array (and `openingDetailSourceKey`) was a dependency of that one
/// body, so each of `loadHome`'s staggered fetches re-ran it and every
/// `ForEach` rebuilt every `MediaCard` (about 120 `CachedAsyncImage.init`s,
/// each a lock and an NSCache lookup) before `.equatable()` could skip one.
struct HomeShelf: View {
    enum Skeleton { case never, whenLoading, whenSignedInAndLoading }

    let model: AppModel
    let title: String
    let shelfKey: String
    let items: KeyPath<AppModel, [MediaCard.Item]>
    var skeleton: Skeleton = .whenLoading
    var requiresSignIn = false
    let namespace: Namespace.ID
    let onOpenDetail: (Int64, String, URL?, Bool, String?) -> Void

    private var showsSkeleton: Bool {
        switch skeleton {
        case .never: false
        case .whenLoading: model.isLoading
        case .whenSignedInAndLoading: model.isSignedIn && model.isLoading
        }
    }

    var body: some View {
        if requiresSignIn && !model.isSignedIn {
            EmptyView()
        } else {
            let items = model[keyPath: items]
            if !items.isEmpty {
                shelf(items: items)
            } else if showsSkeleton {
                MediaRowSkeleton(title: title)
            }
        }
    }

    private func card(_ item: MediaCard.Item, key: String) -> some View {
        MediaCard(
            item: item,
            namespace: model.openingDetailSourceKey == "\(key):\(item.id)" ? namespace : nil,
            onPrefetch: {
                model.prefetchDetail(id: item.id, isManga: item.isManga)
            }
        ) {
            onOpenDetail(item.id, item.title, item.coverImageURL, item.isManga, "\(key):\(item.id)")
        }
        .equatable()
        .frame(width: 180)
    }

    private func shelf(items: [MediaCard.Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(title)
                    .font(.sumiHeading(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)

                Spacer()

                Text("\(items.count) show\(items.count == 1 ? "" : "s")")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        card(item, key: shelfKey)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
