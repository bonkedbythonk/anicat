#if os(iOS)
import SwiftUI

/// The pushed detail page on iPhone.
///
/// Not `MediaDetailView`: that one is an overlay the desktop swaps in over
/// the whole window, with its own back/forward history, a six-tab strip and
/// a two-column body. On a phone the back gesture belongs to the
/// `NavigationStack`, and the tab strip is two segments because Cast & Staff,
/// Related, Discussions and More have no touch layout yet.
struct PhoneDetailView: View {
    @Bindable var model: AppModel

    enum Section: String, CaseIterable, Identifiable {
        case episodes = "Episodes"
        case about = "About"
        var id: String { rawValue }
    }

    @State private var section: Section = .episodes
    @State private var synopsisExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let details = model.selectedMediaDetails {
                    Hero(details: details)

                    Picker("", selection: $section) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    switch section {
                    case .episodes: episodeList
                    case .about: about(details)
                    }
                } else if let message = model.errorMessage {
                    // Without this the page span forever on a failed fetch:
                    // the push happens at tap time, so a detail that never
                    // arrives leaves a spinner with nothing behind it, which
                    // is exactly what an AniList outage looks like here.
                    VStack(spacing: 8) {
                        Text("Could not load this title")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(SumiTheme.foreground)
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SumiTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 80)
                } else {
                    // openDetail is async and the push happens as soon as it
                    // is asked for, so this is the state between the tap and
                    // the fetch landing.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .background(SumiTheme.background)
        .navigationTitle(model.selectedMediaDetails?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // The item is unconditional and the menu handles the not-yet-loaded
        // case: wrapping the `ToolbarItem` itself in `if let` renders no
        // button at all, which is why list editing had no entry point.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { listMenu }
        }
    }

    /// List editing, behind the bar's "...". `updateListEntry` and
    /// `toggleFavourite` already existed on the model and were simply
    /// unreachable from the phone.
    @ViewBuilder
    private var listMenu: some View {
        let details = model.selectedMediaDetails
        Menu {
            Picker("Status", selection: Binding(
                get: { details?.listStatus ?? "" },
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
            Button {
                Task { await model.toggleFavourite() }
            } label: {
                Label(details?.isFavourite == true ? "Remove from favourites" : "Add to favourites",
                      systemImage: details?.isFavourite == true ? "heart.fill" : "heart")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(details == nil)
    }

    @ViewBuilder
    private var episodeList: some View {
        if model.selectedEpisodes.isEmpty {
            Text("No episodes listed.")
                .font(.system(size: 13))
                .foregroundStyle(SumiTheme.muted)
                .padding(.horizontal, 16)
                .padding(.top, 24)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(model.selectedEpisodes) { episode in
                    Button {
                        // `resolveAndPlay`, not `playSelectedEpisode`: that
                        // one guards on `currentPlaybackCatalogId` and
                        // `playbackEpisodes`, both of which only exist once
                        // something is already playing, so from a freshly
                        // pushed page it returned silently and the tap did
                        // nothing at all. `resolveAndPlay` is what sets them,
                        // via `ensurePlaybackEpisodes`.
                        play(episode.number)
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(SumiTheme.border)
                }
            }
        }
    }

    private func play(_ number: Int) {
        guard let details = model.selectedMediaDetails else { return }
        model.activeResolveTask = Task {
            do {
                _ = try await model.resolveAndPlay(
                    catalogId: details.id,
                    episode: Int64(number),
                    title: details.title
                )
            } catch is CancellationError {
                // The viewer cancelled the "Finding a stream" overlay.
            } catch {
                model.errorMessage = "Failed to play episode \(number): \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func about(_ details: HeroBanner.Details) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let next = details.nextEpisodeText, !next.isEmpty {
                Text(next.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SumiTheme.indigo)
            }

            factRow(details)

            if let synopsis = details.synopsis, !synopsis.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(synopsis)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(SumiTheme.foreground.opacity(0.85))
                        .lineLimit(synopsisExpanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(synopsisExpanded ? "Show less" : "Read more") {
                        withAnimation(.snappy) { synopsisExpanded.toggle() }
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }

            if !details.genres.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("GENRES")
                    FlowChips(items: details.genres) { _ in }
                }
            }

            // Every credited studio is a production committee of licensors
            // and music labels; `isMain` is the animation studio, which is
            // the only one worth a line on a phone.
            if let studios = details.studios, !studios.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    metaLabel("STUDIO")
                    Text(studios.filter(\.isMain).map(\.name).joined(separator: ", "))
                        .font(.system(size: 13))
                        .foregroundStyle(SumiTheme.foreground)
                }
            } else if let studio = details.studio {
                VStack(alignment: .leading, spacing: 6) {
                    metaLabel("STUDIO")
                    Text(studio)
                        .font(.system(size: 13))
                        .foregroundStyle(SumiTheme.foreground)
                }
            }

            if !model.selectedCharacters.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("CAST")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(model.selectedCharacters) { character in
                                castCard(character).sumiShelfEdge()
                            }
                        }
                    }
                    // The row is inset from the page's own 16pt gutter, so it
                    // has to bleed back out to the screen edge or the first
                    // card looks indented against every other row.
                    .padding(.horizontal, -16)
                    .safeAreaPadding(.horizontal, 16)
                }
            }

            if !model.selectedRecommendations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("MORE LIKE THIS")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(model.selectedRecommendations) { item in
                                posterCard(id: item.id, title: item.title, cover: item.coverURL)
                                    .sumiShelfEdge()
                            }
                        }
                    }
                    .padding(.horizontal, -16)
                    .safeAreaPadding(.horizontal, 16)
                }
            }

            if !model.selectedRelations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("RELATED")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(model.selectedRelations) { item in
                                posterCard(
                                    id: item.id,
                                    title: item.title,
                                    cover: item.coverURL,
                                    caption: item.relationType.replacingOccurrences(of: "_", with: " ").capitalized
                                )
                                .sumiShelfEdge()
                            }
                        }
                    }
                    .padding(.horizontal, -16)
                    .safeAreaPadding(.horizontal, 16)
                }
            }

            if details.prequel != nil || details.sequel != nil {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("SEASONS")
                    if let prequel = details.prequel { relationRow("Previous", prequel) }
                    if let sequel = details.sequel { relationRow("Next", sequel) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
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
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 12) {
                ForEach(facts, id: \.0) { fact in
                    VStack(alignment: .leading, spacing: 3) {
                        metaLabel(fact.0)
                        Text(fact.1)
                            .font(.system(size: 13))
                            .foregroundStyle(SumiTheme.foreground)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relationRow(_ role: String, _ relation: HeroBanner.Details.Relation) -> some View {
        Button {
            Task { await model.openDetail(id: relation.id, title: relation.title, coverURL: relation.coverURL) }
        } label: {
            HStack(spacing: 10) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: relation.coverURL, maxPixelSize: 160) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { SumiTheme.card }
                    }
                    .frame(width: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.uppercased())
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SumiTheme.muted)
                    Text(relation.title)
                        .font(.system(size: 13))
                        .foregroundStyle(SumiTheme.foreground)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SumiTheme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A character and, when AniList has one, the actor who voices them.
    /// Both faces on one card: the pairing is the information, and two
    /// separate rows would make the reader match them up by position.
    @ViewBuilder
    private func castCard(_ character: MediaDetailView.CharacterItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: -10) {
                circleImage(character.imageURL, size: 46)
                if let actor = character.voiceActorImageURL {
                    circleImage(actor, size: 46)
                        .overlay(Circle().stroke(SumiTheme.background, lineWidth: 2))
                }
            }
            Text(character.name)
                .font(.system(size: 12))
                .foregroundStyle(SumiTheme.foreground)
                .lineLimit(1)
            Text(character.voiceActorName ?? character.role.capitalized)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SumiTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 104, alignment: .leading)
    }

    @ViewBuilder
    private func circleImage(_ url: URL?, size: CGFloat) -> some View {
        CachedAsyncImage(url: url, maxPixelSize: 160) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: { SumiTheme.card }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    @ViewBuilder
    private func posterCard(id: Int64, title: String, cover: URL?, caption: String? = nil) -> some View {
        Button {
            Task { await model.openDetail(id: id, title: title, coverURL: cover) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: cover, maxPixelSize: 300) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { SumiTheme.card }
                    }
                    .frame(width: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                if let caption {
                    Text(caption.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SumiTheme.indigo)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: 96, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(SumiTheme.muted)
    }

    /// The show's own airing status. Kept apart from `listStatus` because
    /// AniList's two vocabularies collide: one map for both put CURRENT and
    /// RELEASING on the same case, so a title the viewer was *watching* read
    /// "ON YOUR LIST: Airing".
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

    /// Where the title sits on the viewer's own list.
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

    private struct Hero: View {
        let details: HeroBanner.Details

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    // `Color.clear` sets the box and the artwork is an
                    // overlay on it, rather than the image being framed
                    // directly. An image with `contentMode: .fill` and only
                    // its height pinned reports the width that covers that
                    // height — about 900pt for a banner — and a `maxWidth`
                    // frame centres an oversized child instead of shrinking
                    // it, so that width became the whole page's width and the
                    // column rendered with its left half off the screen.
                    Color.clear
                        .frame(height: 250)
                        .overlay {
                            CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 900) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                SumiTheme.card
                            }
                        }
                        .clipped()
                        // The art runs up under the status bar. Before this it
                        // started below the navigation bar and met the black
                        // page in a hard horizontal line across the screen.
                        .ignoresSafeArea(edges: .top)
                        // Its own scrim, so the back chevron and title stay
                        // readable over a bright banner.
                        .overlay(alignment: .top) {
                            LinearGradient(
                                colors: [.black.opacity(0.55), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 120)
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                        }

                    // The title sits on the artwork, so it needs its own
                    // ground: a bright banner made white text unreadable.
                    LinearGradient(
                        colors: [.clear, SumiTheme.background.opacity(0.95)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 190)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(SumiTheme.foreground)
                            .lineLimit(2)
                        Text(metaLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SumiTheme.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .frame(height: 190)
                .clipped()
            }
        }

        private var metaLine: String {
            var parts: [String] = []
            if let score = details.averageScore { parts.append("\(Double(score) / 10.0)") }
            if let year = details.year { parts.append("\(year)") }
            if let count = details.episodeCount { parts.append("\(count) EPS") }
            return parts.joined(separator: " · ")
        }
    }

    private struct EpisodeRow: View {
        let episode: MediaDetailView.EpisodeItem

        var body: some View {
            HStack(spacing: 12) {
                ZStack {
                    CachedAsyncImage(url: episode.thumbnailURL, maxPixelSize: 200) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        SumiTheme.card
                    }
                    .frame(width: 64, height: 40)
                    .clipped()
                    if episode.isWatched {
                        Color.black.opacity(0.45)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                // `lineLimit(1)` truncates the drawing, not the layout: the
                // row still asked for the full width of the longest episode
                // title, the stack took the widest row as its own width, and
                // the whole page centred on that — the left half rendered off
                // the screen. The explicit frame is what makes it truncate.
                VStack(alignment: .leading, spacing: 3) {
                    Text("EP \(episode.number)\(episode.title.isEmpty ? "" : " · \(episode.title)")")
                        .font(.system(size: 14))
                        .foregroundStyle(episode.isWatched ? SumiTheme.muted : SumiTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let runtime = episode.runtimeMinutes {
                        Text("\(runtime) MIN")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(SumiTheme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
    }
}
#endif
