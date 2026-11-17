#if os(tvOS)
import SwiftUI
import AnicatCoreKit

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
    /// The series season the episode row shows; nil follows Resume.
    @State private var pickedSeason: Int?
    @Namespace private var pageFocus

    private var catalog: MediaCard.CardCatalog { model.currentDetailCatalog }
    private var isFilm: Bool { catalog == .tmdbMovie }
    private var isSeries: Bool { catalog == .tmdbTv }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let details = model.selectedMediaDetails {
                    Hero(details: details, catalog: catalog, extras: model.cinemaExtras) {
                        actions(details)
                    }
                    if !isFilm { episodeList }
                    cast
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
        .background {
            // The cover's colour, low behind the episodes and cast, as on
            // the Up Next backdrop. `indigo` is the cover's hue here: the
            // task below sets it, as the Mac's detail page does.
            ZStack {
                SumiTheme.background
                RadialGradient(
                    colors: [SumiTheme.indigo.opacity(0.22), .clear],
                    center: .bottom,
                    startRadius: 0,
                    endRadius: 1400
                )
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .top)
        .task(id: model.selectedMediaDetails?.coverURL) { await followCoverAccent() }
        .onChange(of: model.selectedMediaDetails?.id) { _, _ in pickedSeason = nil }
        .onDisappear {
            ThemeStore.shared.releaseAccentOverride(owner: model.selectedMediaDetails?.coverURL?.absoluteString ?? "")
        }
    }

    @AppStorage(ThemeStore.posterAccentKey) private var posterAccentEnabled = true

    /// The page's accent from its cover, through the same store and owner
    /// rule as `MediaDetailView.followPosterAccent`, so Play, the progress
    /// bars and the glow take the show's colour.
    private func followCoverAccent() async {
        let cover = model.selectedMediaDetails?.coverURL
        let owner = cover?.absoluteString ?? ""
        guard posterAccentEnabled, let cover,
              let image = await ImageDecodeCache.shared.image(for: cover, maxPixelSize: 600),
              !Task.isCancelled else {
            ThemeStore.shared.setAccentOverride(nil, owner: owner)
            return
        }
        ThemeStore.shared.setAccentOverride(PosterAccent.accent(for: image, isLight: ThemeStore.shared.palette.isLight), owner: owner)
    }

    // MARK: Actions

    /// Play (or Resume), and for anime the list status and the favourite,
    /// in the row a viewer arriving from a poster lands on first.
    @ViewBuilder
    private func actions(_ details: HeroBanner.Details) -> some View {
        HStack(spacing: 24) {
            if let resume = details.resumeEpisode {
                Button {
                    play(resume)
                } label: {
                    Label("Resume\(episodeLabel(resume))", anicat: "play.fill")
                        .fontWeight(.semibold)
                }
                .sumiPrimaryButton()
                .prefersDefaultFocus(in: pageFocus)
            } else if let first = model.selectedEpisodes.first(where: { !$0.isWatched && $0.isAired })
                        ?? model.selectedEpisodes.first {
                Button {
                    play(first.number)
                } label: {
                    Label("Play\(episodeLabel(first.number))", anicat: "play.fill")
                        .fontWeight(.semibold)
                }
                .sumiPrimaryButton()
                .prefersDefaultFocus(in: pageFocus)
            }

            // A film's or series' place on this TV's own list. The Library's
            // Films & TV page reads it, and nothing on the TV could set it.
            if catalog != .anilist {
                Menu {
                    Picker("List", selection: Binding(
                        get: { model.cinemaListStatus ?? "" },
                        set: { model.setCinemaListStatus($0.isEmpty ? nil : $0) }
                    )) {
                        ForEach(Self.cinemaStatuses, id: \.raw) { Text($0.label).tag($0.raw) }
                    }
                    if model.cinemaListStatus != nil {
                        Button("Remove from list", role: .destructive) { model.setCinemaListStatus(nil) }
                    }
                } label: {
                    Label(
                        Self.cinemaStatuses.first { $0.raw == model.cinemaListStatus }?.label ?? "Add to list",
                        anicat: "list.bullet"
                    )
                }
            }

            // AniList's list and favourite. A film or series is not on
            // AniList, and these wrote to whatever anime shares its id.
            if catalog == .anilist, model.isSignedIn, details.listEntryId != nil || details.listStatus == nil {
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
                    Label(details.listStatus.map(TVDetailView.listStatus) ?? "Add to list", anicat: "list.bullet")
                }

                Button {
                    Task { await model.toggleFavourite() }
                } label: {
                    Image(anicat: details.isFavourite ? "heart.fill" : "heart")
                }
            }
        }
        .focusScope(pageFocus)
        .focusSection()
    }

    /// The local list's statuses, named as on the Mac's Films & TV page.
    static let cinemaStatuses: [(raw: String, label: String)] = [
        ("PLANNING", "Planning"), ("CURRENT", "Watching"), ("COMPLETED", "Completed"), ("DROPPED", "Dropped"),
    ]

    /// " episode 4" for anime, " S2 E3" for a series, nothing for a film,
    /// which has one "episode" that is the film.
    private func episodeLabel(_ number: Int) -> String {
        if isFilm { return "" }
        if isSeries, let place = seasonPlace(number) { return " S\(place.season) E\(place.episode)" }
        return " episode \(number)"
    }

    private func seasonPlace(_ absolute: Int) -> (season: Int, episode: Int)? {
        AppModel.presenceSeasonPlace(absoluteEpisode: absolute, seasons: model.cinemaExtras?.seasons ?? [])
    }

    // MARK: Episodes

    /// The seasons that have episodes, in TMDB's order.
    private var seasons: [Int] {
        guard isSeries else { return [] }
        return (model.cinemaExtras?.seasons ?? []).filter { $0.episodeCount > 0 }.map { Int($0.number) }
    }

    private var shownSeason: Int? {
        if let pickedSeason { return pickedSeason }
        let anchor = model.selectedMediaDetails?.resumeEpisode
            ?? model.selectedEpisodes.first(where: { !$0.isWatched && $0.isAired })?.number
        return anchor.flatMap { seasonPlace($0)?.season } ?? seasons.first
    }

    private var shownEpisodes: [MediaDetailView.EpisodeItem] {
        guard let season = shownSeason, seasons.count > 1 else { return model.selectedEpisodes }
        return model.selectedEpisodes.filter { seasonPlace($0.number)?.season == season }
    }

    @ViewBuilder
    private var episodeList: some View {
        if model.selectedEpisodes.isEmpty {
            Text("No episodes listed.")
                .font(.system(size: 24))
                .foregroundStyle(SumiTheme.muted)
                .padding(.horizontal, TVMetrics.gutter)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 30) {
                    TVSectionHeader("Episodes")
                    if seasons.count > 1, let season = shownSeason {
                        Menu {
                            Picker("Season", selection: Binding(
                                get: { season },
                                set: { pickedSeason = $0 }
                            )) {
                                ForEach(seasons, id: \.self) { number in
                                    Text(number == 0 ? "Specials" : "Season \(number)").tag(number)
                                }
                            }
                        } label: {
                            Text(season == 0 ? "Specials" : "Season \(season)")
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                }
                .padding(.trailing, TVMetrics.gutter)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: TVMetrics.shelfSpacing) {
                        ForEach(shownEpisodes) { episode in
                            EpisodeCard(
                                episode: episode,
                                displayNumber: isSeries ? (seasonPlace(episode.number)?.episode ?? episode.number) : episode.number
                            ) {
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
        model.activeResolveTask?.cancel()
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

    // MARK: Cast

    /// Anime: characters with their voice actors, each opening the
    /// character's page. Films and series: actors with the part they play,
    /// each opening the actor's page. TMDB person ids sent to the character
    /// page opened whatever AniList character shared the number.
    @ViewBuilder
    private var cast: some View {
        if !model.selectedCharacters.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader("Cast")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: TVMetrics.shelfSpacing) {
                        ForEach(model.selectedCharacters) { character in
                            TVPersonCard(
                                imageURL: character.imageURL?.absoluteString,
                                title: character.name,
                                subtitle: catalog == .anilist
                                    ? (character.voiceActorName ?? MediaCard.displayRelation(character.role))
                                    : character.role
                            ) {
                                if catalog == .anilist {
                                    model.openCharacter(id: character.id)
                                } else {
                                    model.openCinemaPerson(id: character.id, name: character.name)
                                }
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

    // MARK: About

    @ViewBuilder
    private func about(_ details: HeroBanner.Details) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            if let next = details.nextEpisodeText, !next.isEmpty {
                Text(next)
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(SumiTheme.indigo)
            }

            if let synopsis = details.synopsis, !synopsis.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    TVSectionHeader("About")
                        .padding(.leading, -TVMetrics.gutter)
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
                    metaLabel("Genres")
                    Text(details.genres.joined(separator: " · "))
                        .font(.system(size: 24))
                        .foregroundStyle(SumiTheme.foreground)
                }
            }

            if catalog != .anilist {
                if let companies = model.cinemaExtras?.companies, !companies.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        metaLabel(isSeries ? "Network" : "Studio")
                        Text(companies.prefix(4).joined(separator: " · "))
                            .font(.system(size: 24))
                            .foregroundStyle(SumiTheme.foreground)
                    }
                }
            } else if let studios = details.studios?.filter(\.isMain), !studios.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    metaLabel("Studio")
                    // Each opens the studio's other work.
                    HStack(spacing: 20) {
                        ForEach(studios) { studio in
                            Button(studio.name) { model.openStudio(id: studio.id) }
                                .font(.system(size: 24))
                        }
                    }
                }
            } else if let studio = details.studio {
                VStack(alignment: .leading, spacing: 10) {
                    metaLabel("Studio")
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
                    MediaCard.Item(
                        id: $0.id, title: $0.title, coverImageURL: $0.coverURL, score: $0.averageScore,
                        catalog: catalog == .anilist ? nil : ($0.format == "TV" ? .tmdbTv : .tmdbMovie)
                    )
                },
                onOpen: open
            )
        }

        if model.selectedRelations.contains(where: { !AppModel.isMangaFormat($0.format) }) {
            TVPosterShelf(
                title: "Related",
                // Not the manga and novels: the TV has no reader, and opening
                // one led to a page with nothing to play.
                items: model.selectedRelations.filter { !AppModel.isMangaFormat($0.format) }.map {
                    MediaCard.Item(id: $0.id, title: $0.title, coverImageURL: $0.coverURL)
                },
                onOpen: open
            )
        }
    }

    /// A poster on this page, through its own catalog: a film's "More
    /// Like This" sent to `openDetail` opened the anime with that id.
    private func open(_ item: MediaCard.Item) {
        Task {
            if let catalog = item.catalog, catalog != .anilist {
                await model.openCinemaDetail(item)
            } else {
                await model.openDetail(id: item.id, title: item.title, coverURL: item.coverImageURL)
            }
        }
    }

    private func facts(_ details: HeroBanner.Details) -> [(String, String)] {
        let extras = model.cinemaExtras
        let facts: [(String, String)]
        if catalog == .anilist {
            facts = [
                ("Status", details.status.map(Self.mediaStatus)),
                ("Format", details.format.map(MediaCard.displayFormat)),
                ("Episodes", details.episodeCount.map(String.init)),
                ("Score", details.averageScore.map { String(format: "%.1f", Double($0) / 10) }),
                ("Your score", details.userScore.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }),
                ("On your list", details.listStatus.map(Self.listStatus))
            ].compactMap { name, value in value.map { (name, $0) } }
        } else {
            facts = [
                (isSeries ? "First aired" : "Released", extras?.releaseDate.flatMap(Self.longDate)),
                (isSeries ? "Last aired" : nil, extras?.lastAirDate.flatMap(Self.longDate)),
                ("Runtime", isFilm ? extras?.runtimeMinutes.map { Self.runtime(Int($0)) } : nil),
                ("Seasons", isSeries ? extras?.seasonCount.map(String.init) : nil),
                ("Episodes", isSeries ? extras?.episodeCount.map(String.init) : nil),
                ("Language", extras?.originalLanguage.flatMap { Locale.current.localizedString(forLanguageCode: $0) }),
                ("Score", details.averageScore.map { String(format: "%.1f", Double($0) / 10) })
            ].compactMap { name, value in
                guard let name, let value else { return nil }
                return (name, value)
            }
        }
        return facts
    }

    @ViewBuilder
    private func factRow(_ details: HeroBanner.Details) -> some View {
        let facts = facts(details)
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
            .font(.system(size: 18, weight: .semibold)).monospacedDigit()
            .foregroundStyle(SumiTheme.muted)
    }

    /// "2 h 9 min", "48 min".
    static func runtime(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// TMDB's "2024-03-01" as "1 March 2024" in the viewer's locale.
    static func longDate(_ raw: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return nil }
        return date.formatted(date: .long, time: .omitted)
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

    /// The first screen: the artwork across all of it, fading into the page
    /// by transparency rather than into a colour. The old banner stopped at
    /// 620pt with a gradient to the plain background over a page with a
    /// coloured glow, and the owner saw "the hard cut in the middle".
    private struct Hero<Actions: View>: View {
        let details: HeroBanner.Details
        let catalog: MediaCard.CardCatalog
        let extras: CinemaExtras?
        @ViewBuilder let actions: () -> Actions

        /// Short of the full 1080 so the next row's title shows under it and
        /// says there is more below.
        private let height: CGFloat = 900

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                // `Color.clear` sets the box and the artwork is an overlay
                // on it. Framed directly, a 4.75:1 AniList banner filled to
                // 900pt reported ~4300pt of width, the page grew to match,
                // and the title and every header slid off the left edge.
                Color.clear
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .overlay { artwork }
                    .clipped()
                    // Darker under the words on the left; part of the
                    // artwork, so the fade below takes it away too.
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.7), .black.opacity(0.25), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.45),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    // Out past tvOS's side safe area, which is 80pt on a
                    // 1920pt screen: inside it the artwork stopped short of
                    // both edges. `ignoresSafeArea` does nothing inside the
                    // scroll view, which does not clip.
                    .padding(.horizontal, -80)

                VStack(alignment: .leading, spacing: 18) {
                    Text(details.title)
                        .font(.sumiHeading(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.4), radius: 12)
                    if !metaLine.isEmpty {
                        Text(metaLine)
                            .font(.system(size: 24, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if let line = leadLine {
                        Text(line)
                            .font(.system(size: 24))
                            .lineSpacing(4)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                    actions()
                        .padding(.top, 14)
                }
                .padding(.horizontal, TVMetrics.gutter)
                .padding(.bottom, 40)
            }
            .frame(height: height)
        }

        /// A TMDB backdrop is 16:9 and fills the screen. An AniList banner
        /// is about 1900x400: filled, it was blown up four times and soft.
        /// So it sits sharp at the top over a blurred copy of itself.
        @ViewBuilder
        private var artwork: some View {
            if catalog != .anilist {
                CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 1920) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
            } else {
                ZStack(alignment: .top) {
                    CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 600) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        SumiTheme.card
                    }
                    .blur(radius: 60)
                    .opacity(0.7)
                    if let banner = details.bannerURL {
                        CachedAsyncImage(url: banner, maxPixelSize: 1920) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Color.clear
                        }
                        .mask {
                            LinearGradient(
                                stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                }
            }
        }

        private var metaLine: String {
            var parts: [String] = []
            if let year = details.year { parts.append("\(year)") }
            switch catalog {
            case .tmdbMovie:
                if let minutes = extras?.runtimeMinutes { parts.append(TVDetailView.runtime(Int(minutes))) }
            case .tmdbTv:
                if let seasons = extras?.seasonCount { parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons") }
            default:
                if let count = details.episodeCount { parts.append("\(count) eps") }
                if let format = details.format { parts.append(MediaCard.displayFormat(format)) }
            }
            parts.append(contentsOf: details.genres.prefix(2))
            if let score = details.averageScore { parts.append(String(format: "%.1f", Double(score) / 10)) }
            return parts.joined(separator: " · ")
        }

        /// A film's tagline when it has one; otherwise nothing here, the
        /// synopsis is further down.
        private var leadLine: String? {
            guard let tagline = extras?.tagline, !tagline.isEmpty, catalog != .anilist else { return nil }
            return tagline
        }
    }

    // MARK: Episode card

    /// One episode: a still with the number on it, the title under it. A
    /// press plays; a long press on the remote's touch surface offers the
    /// watched toggle through the context menu, which is the only way to
    /// take a watch back on the TV.
    private struct EpisodeCard: View {
        let episode: MediaDetailView.EpisodeItem
        /// The number on the still: the absolute number for anime, the
        /// number within its season for a series.
        let displayNumber: Int
        let onPlay: () -> Void
        let onToggleWatched: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: TVMetrics.cardTitleGap) {
                Button(action: onPlay) {
                    ZStack(alignment: .bottomLeading) {
                        CachedAsyncImage(url: episode.thumbnailURL, maxPixelSize: 800) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            TVMetrics.placeholder
                        }
                        .frame(width: TVMetrics.thumbWidth, height: TVMetrics.thumbHeight)
                        .clipped()

                        if episode.isWatched {
                            Color.black.opacity(0.45)
                            Image(anicat: "checkmark.circle.fill")
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

                        Text("\(displayNumber)")
                            .font(.system(size: 20, weight: .bold)).monospacedDigit()
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

                Text(episode.title.isEmpty ? "Episode \(displayNumber)" : episode.title)
                    .font(.system(size: 22))
                    .foregroundStyle(episode.isWatched ? SumiTheme.muted : SumiTheme.foreground)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                if let runtime = episode.runtimeMinutes {
                    Text("\(runtime) min")
                        .font(.system(size: 18)).monospacedDigit()
                        .foregroundStyle(SumiTheme.muted)
                } else if !episode.isAired, let airDate = episode.airDate {
                    Text(airDate)
                        .font(.system(size: 18)).monospacedDigit()
                        .foregroundStyle(SumiTheme.muted)
                }
            }
            .frame(width: TVMetrics.thumbWidth, alignment: .leading)
        }
    }
}
#endif
