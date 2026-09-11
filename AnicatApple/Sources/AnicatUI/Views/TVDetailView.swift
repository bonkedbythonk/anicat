#if os(tvOS)
import SwiftUI

/// The pushed detail page on Apple TV.
///
/// Not `MediaDetailView`: that one is an overlay with its own back/forward
/// history, a six-tab strip and a two-column body, all of it laid out for a
/// pointer. Here the back gesture belongs to the `NavigationStack` (the
/// Menu button pops it), and the page is one column: the banner, a row of
/// actions the remote can land on, the episodes, and the facts below them.
struct TVDetailView: View {
    @Bindable var model: AppModel

    @State private var synopsisExpanded = false
    @Namespace private var pageFocus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let details = model.selectedMediaDetails {
                    Hero(details: details)
                    actions(details)
                    episodeList
                    about(details)
                } else if let message = model.errorMessage {
                    // Without this the page spun forever on a failed fetch:
                    // the push happens at press time, so a detail that never
                    // arrives leaves a spinner with nothing behind it.
                    TVEmptyHint(title: "Could not load this title", detail: message)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 200)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .background(SumiTheme.background)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Actions

    /// Play (or Resume), the list status, and the favourite, in the row a
    /// viewer arriving from a poster lands on first.
    @ViewBuilder
    private func actions(_ details: HeroBanner.Details) -> some View {
        HStack(spacing: 24) {
            if let resume = details.resumeEpisode {
                Button {
                    play(resume)
                } label: {
                    Label("Resume episode \(resume)", systemImage: "play.fill")
                }
                .prefersDefaultFocus(in: pageFocus)
            } else if let first = model.selectedEpisodes.first(where: { !$0.isWatched && $0.isAired })
                        ?? model.selectedEpisodes.first {
                Button {
                    play(first.number)
                } label: {
                    Label("Play episode \(first.number)", systemImage: "play.fill")
                }
                .prefersDefaultFocus(in: pageFocus)
            }

            if model.isSignedIn, details.listEntryId != nil || details.listStatus == nil {
                Menu {
                    Picker("Status", selection: Binding(
                        get: { details.listStatus ?? "" },
                        set: { status in
                            Task { await model.updateListEntry(status: status) }
                        }
                    )) {
                        Text("Watching").tag("CURRENT")
                        Text("Planning").tag("PLANNING")
                        Text("Completed").tag("COMPLETED")
                        Text("Paused").tag("PAUSED")
                        Text("Dropped").tag("DROPPED")
                    }
                } label: {
                    Label(details.listStatus.map(TVDetailView.listStatus) ?? "Add to list", systemImage: "list.bullet")
                }

                Button {
                    Task { await model.toggleFavourite() }
                } label: {
                    Image(systemName: details.isFavourite ? "heart.fill" : "heart")
                }
            }
            Spacer()
        }
        .padding(.horizontal, TVMetrics.gutter)
        .focusScope(pageFocus)
        .focusSection()
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodeList: some View {
        if model.selectedEpisodes.isEmpty {
            Text("No episodes listed.")
                .font(.system(size: 24))
                .foregroundStyle(SumiTheme.muted)
                .padding(.horizontal, TVMetrics.gutter)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader("Episodes")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: TVMetrics.shelfSpacing) {
                        ForEach(model.selectedEpisodes) { episode in
                            EpisodeCard(episode: episode) {
                                play(episode.number)
                            } onToggleWatched: {
                                Task { await model.setEpisodeWatched(episode.number, watched: !episode.isWatched) }
                            }
                        }
                    }
                    .padding(.horizontal, TVMetrics.gutter)
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    private func play(_ number: Int) {
        guard let details = model.selectedMediaDetails else { return }
        model.errorRetryAction = nil
        model.activeResolveTask = Task {
            do {
                _ = try await model.resolveAndPlay(
                    // `catalog` defaults to `.anilist`; a TMDB id handed to
                    // the anime catalog matches nothing, so a film's Play
                    // would do nothing at all without this.
                    catalog: model.playbackCatalogForOpenDetail,
                    catalogId: details.id,
                    episode: Int64(number),
                    title: details.title
                )
            } catch is CancellationError {
                // The viewer cancelled the "Finding a stream" card.
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: About

    @ViewBuilder
    private func about(_ details: HeroBanner.Details) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            if let next = details.nextEpisodeText, !next.isEmpty {
                Text(next.uppercased())
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SumiTheme.indigo)
            }

            if let synopsis = details.synopsis, !synopsis.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text(synopsis)
                        .font(.system(size: 26))
                        .lineSpacing(6)
                        .foregroundStyle(SumiTheme.foreground.opacity(0.85))
                        .lineLimit(synopsisExpanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1300, alignment: .leading)
                    Button(synopsisExpanded ? "Show less" : "Read more") {
                        withAnimation(.snappy) { synopsisExpanded.toggle() }
                    }
                }
            }

            factRow(details)

            if !details.genres.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    metaLabel("GENRES")
                    Text(details.genres.joined(separator: " · "))
                        .font(.system(size: 24))
                        .foregroundStyle(SumiTheme.foreground)
                }
            }

            if let studios = details.studios, !studios.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    metaLabel("STUDIO")
                    Text(studios.filter(\.isMain).map(\.name).joined(separator: ", "))
                        .font(.system(size: 24))
                        .foregroundStyle(SumiTheme.foreground)
                }
            } else if let studio = details.studio {
                VStack(alignment: .leading, spacing: 10) {
                    metaLabel("STUDIO")
                    Text(studio)
                        .font(.system(size: 24))
                        .foregroundStyle(SumiTheme.foreground)
                }
            }
        }
        .padding(.horizontal, TVMetrics.gutter)

        if !model.selectedRecommendations.isEmpty {
            TVPosterShelf(
                title: "More Like This",
                items: model.selectedRecommendations.map {
                    MediaCard.Item(id: $0.id, title: $0.title, coverImageURL: $0.coverURL, score: $0.averageScore)
                },
                onOpen: { item in
                    Task { await model.openDetail(id: item.id, title: item.title, coverURL: item.coverImageURL) }
                }
            )
        }

        if !model.selectedRelations.isEmpty {
            TVPosterShelf(
                title: "Related",
                items: model.selectedRelations.map {
                    MediaCard.Item(id: $0.id, title: $0.title, coverImageURL: $0.coverURL)
                },
                onOpen: { item in
                    Task { await model.openDetail(id: item.id, title: item.title, coverURL: item.coverImageURL) }
                }
            )
        }
    }

    @ViewBuilder
    private func factRow(_ details: HeroBanner.Details) -> some View {
        let facts: [(String, String)] = [
            ("STATUS", details.status.map(Self.mediaStatus)),
            ("FORMAT", details.format),
            ("EPISODES", details.episodeCount.map(String.init)),
            ("SCORE", details.averageScore.map { String(format: "%.1f", Double($0) / 10) }),
            ("YOUR SCORE", details.userScore.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }),
            ("ON YOUR LIST", details.listStatus.map(Self.listStatus))
        ].compactMap { name, value in value.map { (name, $0) } }

        if !facts.isEmpty {
            HStack(alignment: .top, spacing: 60) {
                ForEach(facts, id: \.0) { fact in
                    VStack(alignment: .leading, spacing: 6) {
                        metaLabel(fact.0)
                        Text(fact.1)
                            .font(.system(size: 24))
                            .foregroundStyle(SumiTheme.foreground)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .foregroundStyle(SumiTheme.muted)
    }

    /// The show's own airing status. Kept apart from `listStatus` because
    /// AniList's two vocabularies collide on CURRENT/RELEASING.
    static func mediaStatus(_ raw: String) -> String {
        switch raw {
        case "RELEASING": return "Airing"
        case "FINISHED": return "Finished"
        case "NOT_YET_RELEASED": return "Unaired"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "On hiatus"
        default: return raw.capitalized
        }
    }

    static func listStatus(_ raw: String) -> String {
        switch raw {
        case "CURRENT": return "Watching"
        case "PLANNING": return "Planning"
        case "COMPLETED": return "Completed"
        case "PAUSED": return "Paused"
        case "DROPPED": return "Dropped"
        case "REPEATING": return "Rewatching"
        default: return raw.capitalized
        }
    }

    // MARK: Hero

    private struct Hero: View {
        let details: HeroBanner.Details

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                // `Color.clear` sets the box and the artwork is an overlay
                // on it: an image with `.fill` and only its height pinned
                // reports the width that covers that height, and a
                // `maxWidth` frame centres an oversized child instead of
                // shrinking it. See `PhoneDetailView.Hero`.
                Color.clear
                    .frame(height: 620)
                    .overlay {
                        CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 1920) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            SumiTheme.card
                        }
                    }
                    .clipped()

                LinearGradient(
                    colors: [.clear, SumiTheme.background.opacity(0.85), SumiTheme.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 400)

                HStack(alignment: .bottom, spacing: 40) {
                    CachedAsyncImage(url: details.coverURL, maxPixelSize: 600) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        SumiTheme.card
                    }
                    .frame(width: 200, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(details.title)
                            .font(.sumiHeading(size: 52, weight: .bold))
                            .foregroundStyle(SumiTheme.foreground)
                            .lineLimit(2)
                        Text(metaLine)
                            .font(.system(size: 22, design: .monospaced))
                            .foregroundStyle(SumiTheme.muted)
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, TVMetrics.gutter)
            }
            .frame(height: 620)
        }

        private var metaLine: String {
            var parts: [String] = []
            if let score = details.averageScore { parts.append(String(format: "%.1f", Double(score) / 10)) }
            if let year = details.year { parts.append("\(year)") }
            if let count = details.episodeCount { parts.append("\(count) EPS") }
            if let format = details.format { parts.append(format) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Episode card

    /// One episode: a still with the number on it, the title under it. A
    /// press plays; a long press on the remote's touch surface offers the
    /// watched toggle through the context menu, which is the only way to
    /// take a watch back on the TV.
    private struct EpisodeCard: View {
        let episode: MediaDetailView.EpisodeItem
        let onPlay: () -> Void
        let onToggleWatched: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onPlay) {
                    ZStack(alignment: .bottomLeading) {
                        CachedAsyncImage(url: episode.thumbnailURL, maxPixelSize: 800) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            SumiTheme.card
                        }
                        .frame(width: TVMetrics.thumbWidth, height: TVMetrics.thumbHeight)
                        .clipped()

                        if episode.isWatched {
                            Color.black.opacity(0.45)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        if let progress = episode.progressPercent, progress > 0, !episode.isWatched {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(SumiTheme.indigo)
                                    .frame(width: geo.size.width * progress / 100, height: 6)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }

                        Text("\(episode.number)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .padding(10)
                    }
                    .frame(width: TVMetrics.thumbWidth, height: TVMetrics.thumbHeight)
                }
                .buttonStyle(.card)
                .disabled(!episode.isAired)
                .contextMenu {
                    Button(episode.isWatched ? "Mark as Unwatched" : "Mark as Watched", action: onToggleWatched)
                }

                Text(episode.title.isEmpty ? "Episode \(episode.number)" : episode.title)
                    .font(.system(size: 22))
                    .foregroundStyle(episode.isWatched ? SumiTheme.muted : SumiTheme.foreground)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                if let runtime = episode.runtimeMinutes {
                    Text("\(runtime) MIN")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(SumiTheme.muted)
                } else if !episode.isAired, let airDate = episode.airDate {
                    Text(airDate.uppercased())
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(SumiTheme.muted)
                }
            }
            .frame(width: TVMetrics.thumbWidth, alignment: .leading)
        }
    }
}
#endif
