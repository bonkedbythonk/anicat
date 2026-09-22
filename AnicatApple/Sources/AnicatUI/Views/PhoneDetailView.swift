#if os(iOS)
import SwiftUI

/// The pushed detail page on iPhone.
///
/// Not `MediaDetailView`: that one is an overlay the desktop swaps in over
/// the whole window, with its own back/forward history, a six-tab strip and
/// a two-column body. On a phone the back gesture belongs to the
/// `NavigationStack`, and the strip is four segments: the list (episodes,
/// chapters or volumes), About, Cast, and More (related, recommendations,
/// discussions). Cast and More were shelves inside About until 2026-09-14,
/// which put the cast forty rows under the synopsis and left nowhere for
/// the threads at all.
struct PhoneDetailView: View {
    @Bindable var model: AppModel

    enum Section: String, CaseIterable, Identifiable {
        case episodes = "Episodes"
        case about = "About"
        case cast = "Cast"
        case more = "More"
        var id: String { rawValue }
    }

    @State private var showTrailer = false

    /// A manga's first segment lists chapters, a light novel's lists
    /// volumes. Same slot, same enum: the label is the only thing that
    /// changes, and `Section` drives the picker's tags, which must not.
    private var isManga: Bool {
        guard let details = model.selectedMediaDetails else { return false }
        return AppModel.isMangaFormat(details.format) || !model.selectedMangaChapters.isEmpty
    }

    /// Lnori volumes are loaded for a NOVEL-format title (`loadDetail`);
    /// while they load the list shows a spinner rather than the empty
    /// chapter list MangaDex would answer for a novel.
    private var isNovel: Bool {
        guard let details = model.selectedMediaDetails else { return false }
        return details.format?.uppercased() == "NOVEL" || !model.novelVolumes.isEmpty
    }

    private var listLabel: String {
        if isNovel { return "Volumes" }
        if isManga { return "Chapters" }
        return "Episodes"
    }

    private var hasTrailer: Bool {
        guard let details = model.selectedMediaDetails, let id = details.trailerId else { return false }
        return TrailerPlayer.embedURL(site: details.trailerSite, videoId: id) != nil
    }

    @State private var section: Section = .episodes
    @State private var synopsisExpanded = false
    // `AppModel.isLnoriEnabled` owns the reader and the default (off);
    // `@AppStorage` needs a literal here, so the two must agree.
    @AppStorage("anicat_lnori_enabled") private var lnoriEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let details = model.selectedMediaDetails {
                    Hero(details: details)

                    Picker("", selection: $section) {
                        ForEach(Section.allCases) {
                            Text($0 == .episodes ? listLabel : $0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    switch section {
                    case .episodes:
                        if isNovel { volumeList(details) } else if isManga { chapterList(details) } else { episodeList }
                    case .about: about(details)
                    case .cast: castGrid
                    case .more: more(details)
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
            if let details {
                // The AniList page, which is the one address everyone can
                // open; the app's own `anicat://` link means nothing to
                // someone without it.
                ShareLink(item: URL(string: "https://anilist.co/\(isManga ? "manga" : "anime")/\(details.id)")!,
                          subject: Text(details.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(details == nil)
    }

    /// Chapters open the reader (`MangaReaderView`, mounted by
    /// `RootTabView`); a long press downloads or removes the download. The
    /// offline state comes from the same dictionary the Mac's rows read.
    @ViewBuilder
    private func chapterList(_ details: HeroBanner.Details) -> some View {
        if model.selectedMangaChapters.isEmpty {
            Text(model.isLoading ? "Looking for chapters..." : "No chapters found.")
                .font(.system(size: 13))
                .foregroundStyle(SumiTheme.muted)
                .padding(.horizontal, 16)
                .padding(.top, 24)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(model.selectedMangaChapters) { chapter in
                    let offline = model.chapterOfflineStates[chapter.id] ?? .none
                    Button {
                        Task {
                            await model.openReader(
                                title: details.title, chapter: chapter,
                                allChapters: model.selectedMangaChapters, anilistId: details.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text("CH \(chapter.number)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(SumiTheme.indigo)
                                .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title.isEmpty ? "Chapter \(chapter.number)" : chapter.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(SumiTheme.foreground)
                                    .lineLimit(1)
                                if let group = chapter.scanlationGroup, !group.isEmpty {
                                    Text(group)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(SumiTheme.muted)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            offlineGlyph(offline)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        switch offline {
                        case .stored:
                            Button(role: .destructive) { model.deleteChapterDownload(chapter) } label: {
                                Label("Remove Download", systemImage: "trash")
                            }
                        case .downloading, .exporting:
                            EmptyView()
                        default:
                            Button { model.downloadChapter(chapter) } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                    Divider().overlay(SumiTheme.border)
                }
            }
        }
    }

    /// Light novel volumes from Lnori: a tap opens the volume in the novel
    /// reader, a long press keeps it (one JSON document, see
    /// `novel_offline.rs`) or removes it.
    @ViewBuilder
    private func volumeList(_ details: HeroBanner.Details) -> some View {
        if !lnoriEnabled {
            // The reason and the switch on one card, so turning it on is
            // not a trip to Settings and back. `loadLightNovelVolumes`
            // returns before the network while it is off and lists only
            // what is already downloaded.
            VStack(alignment: .leading, spacing: 10) {
                Text("Official volumes come from a third-party site that hosts licensed light novels. It is off until you turn it on.")
                    .font(.system(size: 13))
                    .foregroundStyle(SumiTheme.muted)
                Toggle("Official volumes", isOn: $lnoriEnabled)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SumiTheme.foreground)
                Text("Web novels from Syosetu are unaffected.")
                    .font(.system(size: 12))
                    .foregroundStyle(SumiTheme.muted)
            }
            .padding(16)
            .background(SumiTheme.card, in: RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // Downloaded volumes stay listed under the card: they are read
            // from disk and never reach the site the switch is about.
            if !model.novelVolumes.isEmpty {
                volumeRows(details)
            }
        } else if model.novelVolumes.isEmpty {
            if model.isLoadingNovelVolumes {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 32)
            } else {
                Text("No volumes found for this title.")
                    .font(.system(size: 13))
                    .foregroundStyle(SumiTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
            }
        } else {
            volumeRows(details)
        }
    }

    /// The volume rows, shared by the "off" branch (downloaded volumes
    /// only, read from disk) and the normal list.
    @ViewBuilder
    private func volumeRows(_ details: HeroBanner.Details) -> some View {
        let states = model.novelVolumeStates
        LazyVStack(spacing: 0) {
            ForEach(model.novelVolumes, id: \.url) { volume in
                let offline = states[volume.url] ?? .none
                Button {
                    model.openLightNovelVolume(bookURL: volume.url, title: volume.title, catalogId: details.id)
                } label: {
                    HStack(spacing: 12) {
                        // `index` is already 1-based from the engine; +1 showed
                        // "VOL 2" beside "Volume 1".
                        Text("VOL \(volume.index)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SumiTheme.indigo)
                            .frame(width: 64, alignment: .leading)
                        Text(volume.volumeName ?? volume.title)
                            .font(.system(size: 14))
                            .foregroundStyle(SumiTheme.foreground)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        offlineGlyph(offline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    switch offline {
                    case .stored:
                        Button(role: .destructive) { model.deleteNovelVolumeDownload(volume) } label: {
                            Label("Remove Download", systemImage: "trash")
                        }
                    case .downloading, .exporting:
                        EmptyView()
                    default:
                        Button { model.downloadNovelVolume(volume) } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                }
                Divider().overlay(SumiTheme.border)
            }
        }
    }

    @ViewBuilder
    private func offlineGlyph(_ state: MediaDetailView.ChapterOfflineState) -> some View {
        switch state {
        case .stored:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(SumiTheme.indigo)
        case .downloading, .exporting:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(SumiTheme.warning)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func downloadGlyph(_ state: MediaDetailView.EpisodeDownloadState?) -> some View {
        switch state {
        case .done?:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(SumiTheme.indigo)
        case .downloading(let percent)?:
            Text("\(Int(percent))%")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(SumiTheme.muted)
        case .failed?:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(SumiTheme.warning)
        case .notStarted?, nil:
            EmptyView()
        }
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
                        model.playGuardedByCellular { play(episode.number) }
                    } label: {
                        HStack(spacing: 0) {
                            EpisodeRow(episode: episode)
                            downloadGlyph(model.downloadStates[episode.number])
                                .padding(.trailing, 16)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        playOnMac(episode.number)
                        // Same engine path as the Mac's per-row button; the
                        // Downloads page under More lists the result.
                        switch model.downloadStates[episode.number] {
                        case .downloading?, .done?:
                            EmptyView()
                        default:
                            Button {
                                Task { await model.startDownload(episode: episode.number) }
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                        }
                        // The phone had no way to take a watch back. A
                        // stream that failed on open still recorded one, and
                        // the only undo lived in the Mac's History view.
                        Button {
                            Task { await model.setEpisodeWatched(episode.number, watched: !episode.isWatched) }
                        } label: {
                            episode.isWatched
                                ? Label("Mark as Unwatched", systemImage: "minus.circle")
                                : Label("Mark as Watched", systemImage: "checkmark.circle")
                        }
                    }
                    Divider().overlay(SumiTheme.border)
                }
            }
        }
    }

    /// Sends the episode to a Mac on the same Wi-Fi instead of playing it
    /// here. As an `anicat://` address rather than a play command of its
    /// own, so the Mac reaches the episode through `handleDeepLink` -- the
    /// same single entry point a notification tap and the URL scheme use.
    ///
    /// Absent, not disabled, when no Mac is advertising: a menu item that
    /// explains itself only after being pressed is worse than one that is
    /// not there.
    @ViewBuilder
    private func playOnMac(_ number: Int) -> some View {
        if let node = BonjourDiscovery.shared.discoveredMacNode,
           let details = model.selectedMediaDetails {
            Button {
                let link = DeepLink.play(id: details.id, episode: number)
                RemoteClient.shared.send(.open(link: link.url.absoluteString), to: node)
            } label: {
                Label("Play on \(node.name)", systemImage: "macbook")
            }
        }
    }

    private func play(_ number: Int) {
        guard let details = model.selectedMediaDetails else { return }
        model.activeResolveTask = Task {
            do {
                _ = try await model.resolveAndPlay(
                    // Without this the phone resolved every film and series
                    // against AniList: `catalog` defaults to `.anilist`, and
                    // a TMDB id handed to the anime catalog matches nothing,
                    // so a press of Play on a film did nothing at all.
                    catalog: model.playbackCatalogForOpenDetail,
                    catalogId: details.id,
                    episode: Int64(number),
                    title: details.title
                )
            } catch is CancellationError {
                // The viewer cancelled the "Finding a stream" overlay.
            } catch {
                // No "Failed to play episode N:" lead: `resolveAndPlay` throws a
                // `PlaybackFailure` whose description is already the sentence.
                model.errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func about(_ details: HeroBanner.Details) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if hasTrailer {
                Button {
                    showTrailer = true
                } label: {
                    Label("Watch trailer", systemImage: "play.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SumiTheme.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(SumiTheme.indigo, in: Capsule())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showTrailer) {
                    if let id = details.trailerId {
                        TrailerPlayer(
                            site: details.trailerSite, videoId: id,
                            thumbnail: details.trailerThumbnail.flatMap(URL.init(string:)))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(Color.black.ignoresSafeArea())
                        .presentationDetents([.medium, .large])
                    }
                }
            }

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
                    // One button per main studio: each has an AniList id and
                    // a page of its own (`openStudio`).
                    HStack(spacing: 8) {
                        ForEach(studios.filter(\.isMain)) { studio in
                            Button { model.openStudio(id: studio.id) } label: {
                                Text(studio.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(SumiTheme.indigo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if let studio = details.studio {
                VStack(alignment: .leading, spacing: 6) {
                    metaLabel("STUDIO")
                    Text(studio)
                        .font(.system(size: 13))
                        .foregroundStyle(SumiTheme.foreground)
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

    /// Every character with their voice actor, two across. A tap opens the
    /// character page (`PersonPageView` over the tabs); the actor is
    /// reachable from there.
    @ViewBuilder
    private var castGrid: some View {
        if model.selectedCharacters.isEmpty {
            Text(model.isLoading ? "Loading cast..." : "No cast listed.")
                .font(.system(size: 13))
                .foregroundStyle(SumiTheme.muted)
                .padding(.horizontal, 16)
                .padding(.top, 24)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 14) {
                ForEach(model.selectedCharacters) { character in
                    Button { model.openCharacter(id: character.id) } label: {
                        castCard(character)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Related titles, recommendations and the AniList threads, in that
    /// order: the first two are what the Mac's Related and More tabs hold,
    /// the third its Discussions tab. Threads open over the page.
    @ViewBuilder
    private func more(_ details: HeroBanner.Details) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if details.prequel != nil || details.sequel != nil {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("SEASONS")
                    if let prequel = details.prequel { relationRow("Previous", prequel) }
                    if let sequel = details.sequel { relationRow("Next", sequel) }
                }
            }
            if !model.selectedRelations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("RELATED")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 14) {
                        ForEach(model.selectedRelations) { item in
                            posterCard(
                                id: item.id, title: item.title, cover: item.coverURL,
                                caption: item.relationType.replacingOccurrences(of: "_", with: " ").capitalized)
                        }
                    }
                }
            }
            if !model.selectedRecommendations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("MORE LIKE THIS")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 14) {
                        ForEach(model.selectedRecommendations) { item in
                            posterCard(id: item.id, title: item.title, cover: item.coverURL)
                        }
                    }
                }
            }
            if !model.selectedDiscussions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    metaLabel("DISCUSSIONS")
                    ForEach(model.selectedDiscussions) { thread in
                        Button { model.openThread(id: thread.id) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(thread.title)
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(SumiTheme.foreground)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(thread.authorName ?? "AniList") \u{00B7} \(thread.replyCount) \(thread.replyCount == 1 ? "REPLY" : "REPLIES")")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(SumiTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SumiTheme.muted)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(SumiTheme.border)
                    }
                }
            }
            if model.selectedRelations.isEmpty, model.selectedRecommendations.isEmpty,
               model.selectedDiscussions.isEmpty, details.prequel == nil, details.sequel == nil {
                Text("Nothing related yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(SumiTheme.muted)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                            .font(.sumiHeading(size: 22, weight: .bold))
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
