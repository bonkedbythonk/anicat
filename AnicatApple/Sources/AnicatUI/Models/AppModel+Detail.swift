// AppModel, detail domain: opening and closing a title's page with its
// history and forward stack, loading and caching the detail record, and the
// list mutations the page offers (status, watched, favourite, remove).

import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

extension AppModel {
    static func episodeItems(from d: MediaDetail) -> [MediaDetailView.EpisodeItem] {
        d.episodes.map { e in
            MediaDetailView.EpisodeItem(
                id: Int64(e.number),
                number: Int(e.number),
                title: e.title,
                thumbnailURL: e.thumbnail.flatMap(URL.init(string:)),
                isWatched: e.isWatched,
                progressPercent: e.progressPercent,
                synopsis: e.synopsis,
                airDate: e.airDate,
                runtimeMinutes: e.runtimeMinutes.map(Int.init)
            )
        }
        .sorted { $0.number < $1.number }
    }

    /// Opens the detail page for a title, fetching real AniList metadata and real streaming/registry episodes.
    public func openDetail(id: Int64, title: String? = nil, coverURL: URL? = nil, isManga: Bool = false) async {
        // If already loading or displaying this exact title, do not re-trigger or cancel the existing in-flight task
        if loadingCatalogId == id || (selectedMediaDetails?.id == id && !isDetailLoading) {
            if let task = activeDetailTask {
                await task.value
            }
            return
        }

        // Only save current title to history if it's a different title and not a provisional loading placeholder
        if let current = selectedMediaDetails, current.id != id, !isDetailLoading {
            detailHistory.append(currentDetailStep(current))
        }
        detailForwardStack = []
        // A fresh forward navigation (a relation click, not a back/forward
        // step) should use the new page's own default tab, not whatever a
        // previous back-step happened to leave here.
        restoredDetailTab = nil
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        loadingCatalogId = id
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.loadDetail(id: id, title: title, coverURL: coverURL, isManga: isManga)
        }
        activeDetailTask = task
        await task.value
    }

    /// Goes back one level in `detailHistory`, or all the way home when it's
    /// empty. Shared by the swipe-back gesture, the detail page's close
    /// button, and the mouse back button/Alt+Left — matching the web, where
    /// all three call the same `closeDetail`.
    public func closeDetail() {
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        guard let previous = detailHistory.popLast() else {
            // Dropping all the way out to home clears the forward stack —
            // home is the root feed, not a detail page, so forward gestures
            // must never hijack home-screen shelf scrolling or reopen details.
            detailForwardStack = []
            // The poster flies back into the card it came from, so closing
            // reverses the open rather than dissolving over the shelf.
            //
            // `openingDetailSourceKey` is what gives that card its half of
            // the `matchedGeometryEffect` pair (see `HomeShelf`), so clearing
            // it in the same transaction as `selectedMediaDetails` left the
            // leaving poster with nothing to interpolate towards and it
            // simply faded. It is cleared after the animation instead, which
            // is the whole difference between a morph and a cross-fade.
            withAnimation(.sumi(.morph)) {
                selectedMediaDetails = nil
            } completion: { [weak self] in
                self?.openingDetailSourceKey = nil
            }
            return
        }
        // Stepping back to a previous entry in `detailHistory`, not a card
        // tap — no source card to morph from, so this is a plain fade.
        openingDetailSourceKey = nil
        if let current = selectedMediaDetails, !isDetailLoading {
            detailForwardStack.append(currentDetailStep(current))
        }
        restoredDetailTab = previous.tab
        restore(previous)
    }

    /// The step the open page would be, for the stacks.
    func currentDetailStep(_ details: HeroBanner.Details) -> DetailStep {
        DetailStep(
            id: details.id,
            isManga: Self.isMangaFormat(details.format),
            catalog: currentDetailCatalog,
            tab: currentDetailTab
        )
    }

    /// Re-opens one step, through the catalog it belongs to.
    ///
    /// Both directions go through here so a back and a forward cannot
    /// disagree about which path a step reloads on -- and a cinema step must
    /// not reload on AniList's, which is what made Back on a film land on
    /// whatever anime shares its number.
    func restore(_ step: DetailStep) {
        if step.catalog != .anilist {
            let task = Task { [weak self] () -> Void in
                guard let self else { return }
                await self.openCinemaDetail(
                    catalog: step.catalog,
                    id: step.id,
                    title: self.cinemaKnownTitles[CinemaTitleKey(catalog: step.catalog, id: step.id)]
                )
            }
            activeDetailTask = task
            return
        }
        // Load cached snapshot immediately so the transition renders
        // synchronously without waiting for an async Task to start up.
        if let cached = DetailCache.load(id: step.id, isManga: step.isManga) {
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = cached.episodes
                selectedMangaChapters = cached.mangaChapters
                selectedRelations = cached.relations
                selectedRecommendations = cached.recommendations
                selectedCharacters = cached.characters
                selectedDiscussions = cached.discussions
                selectedMediaDetails = cached.details
            }
        }
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.loadDetail(id: step.id, isManga: step.isManga)
        }
        activeDetailTask = task
    }

    public func goForwardDetail() {
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        guard let next = detailForwardStack.popLast() else { return }
        openingDetailSourceKey = nil
        if let current = selectedMediaDetails, !isDetailLoading {
            detailHistory.append(currentDetailStep(current))
        }
        restoredDetailTab = next.tab
        restore(next)
    }

    public nonisolated static func isMangaFormat(_ format: String?) -> Bool {
        format == "MANGA" || format == "NOVEL" || format == "ONE_SHOT"
    }

    /// Closes the detail page and drops the whole `detailHistory`, unlike
    /// `closeDetail()` which pops one level. Use this when leaving the detail
    /// page for somewhere else entirely (switching sidebar sections), where
    /// there's nothing to go "back" to.
    public func clearDetail() {
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        // Same reason as `closeDetail`: the source card has to keep its half
        // of the morph pair until the transition finishes.
        withAnimation(.sumi(.morph)) {
            selectedMediaDetails = nil
        } completion: { [weak self] in
            self?.openingDetailSourceKey = nil
        }
        detailHistory = []
        detailForwardStack = []
    }

    func loadDetail(id: Int64, title: String? = nil, coverURL: URL? = nil, isManga: Bool, forceRefresh: Bool = false) async {
        guard let engine, !Task.isCancelled else { return }
        loadingCatalogId = id
        // Episode numbers repeat across titles, so a stale entry here would
        // show as "downloaded"/"downloading" on the wrong show's episode 1
        // the moment the detail page switches.
        downloadStates = [:]

        // Read before `.load()` touches the file's mtime for its own LRU
        // purposes, or every read would measure as "just saved".
        let cacheAge = DetailCache.ageInSeconds(id: id, isManga: isManga)

        // A cached snapshot renders immediately and the real fetch below
        // still runs and replaces it — this only skips the blank spinner,
        // never the refresh. Without it, every open (even a title seen many
        // times) paid AniList's full round trip up front, and a session
        // that had already made a few other AniList calls could be sitting
        // behind that client's own proactive rate-limit backoff on top of
        // it (see `anilist/client.rs`) — invisible as a "why is this only
        // sometimes slow" spinner instead of the load it actually was.
        let cached = DetailCache.load(id: id, isManga: isManga)
        // Only paint a snapshot over a page that is not already on screen.
        // A refresh of the open page -- what every mark-watched click ends
        // in -- would otherwise replace the optimistic flip the viewer just
        // made with the snapshot written before it, animate that, and
        // animate back a moment later when the fetch lands. The checkbox
        // ticked twice on its way to the state it already had.
        let alreadyShowing = selectedMediaDetails?.id == id
        if let cached, !alreadyShowing {
            isDetailLoading = false
            // Explicit for the same reason as `closeDetail()`: an
            // `.animation(value:)` modifier watching this `@Observable`
            // property doesn't reliably animate its insertion transition.
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = cached.episodes
                selectedMangaChapters = cached.mangaChapters
                selectedRelations = cached.relations
                selectedRecommendations = cached.recommendations
                selectedCharacters = cached.characters
                selectedDiscussions = cached.discussions
                selectedMediaDetails = cached.details
            }
        } else if !alreadyShowing {
            // Optimistic immediate transition: render provisional details and skeletons in 0ms!
            let provisionalTitle = title ?? knownTitles[id] ?? "Loading..."
            let provisional = HeroBanner.Details(
                id: id,
                title: provisionalTitle,
                coverURL: coverURL,
                format: isManga ? "MANGA" : "ANIME"
            )
            isDetailLoading = true
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = []
                selectedMangaChapters = []
                selectedRelations = []
                selectedRecommendations = []
                selectedCharacters = []
                selectedDiscussions = []
                selectedMediaDetails = provisional
            }
        }

        // Cache is recent enough to trust outright — skip the network round
        // trip entirely rather than "render cache, then sync anyway".
        if !forceRefresh, cached != nil, let cacheAge, cacheAge < Self.detailFreshnessWindow {
            loadingCatalogId = nil
            isDetailLoading = false
            // The volumes are not part of the snapshot, so this path has to
            // ask for them even though it is skipping the network otherwise.
            if let shown = selectedMediaDetails, shown.id == id {
                await refreshNovelVolumes(for: shown)
            }
            return
        }

        defer {
            isLoading = false
            if loadingCatalogId == id {
                loadingCatalogId = nil
            }
            if self.selectedMediaDetails?.id == id && self.isDetailLoading {
                self.isDetailLoading = false
            }
        }
        do {
            if Task.isCancelled { return }
            let d: MediaDetail
            if let primary = try? await engine.mediaDetail(catalogId: id, isManga: isManga) {
                d = primary
            } else {
                if Task.isCancelled { return }
                d = try await engine.mediaDetail(catalogId: id, isManga: !isManga)
            }
            if Task.isCancelled { return }
            let episodes = Self.episodeItems(from: d)
            var chapters: [MediaDetailView.MangaChapterItem] = []
            // `mangaChapters` only ever searches MangaDex, which carries
            // manga/manhwa/manhua — never prose light novels. Sending a
            // NOVEL-format title through it wasn't just returning nothing:
            // MangaDex's own title search would occasionally match an
            // unrelated manga with a similar name and hand back ITS
            // chapters, which the reader then opened as if they were the
            // novel's own pages. There is no light-novel content source
            // wired up in the native app yet — see `MediaDetailView`'s
            // `.manga` tab case, which shows a distinct "not available"
            // empty state for `format == "NOVEL"` rather than the generic
            // "no chapters found" a real manga search failure gets.
            //
            // A novel now has a source of its own (`reader::lnori`), but it
            // still must not go down the line above: the hazard that comment
            // describes is MangaDex's, not an absence of anywhere to send it.
            if d.format == "NOVEL" {
                if Task.isCancelled { return }
                if novelVolumesTitle != d.title {
                    novelVolumesTitle = d.title
                    await loadLightNovelVolumes(title: d.title, romajiTitle: d.romajiTitle)
                }
            } else if isManga || d.chapterCount != nil || Self.isMangaFormat(d.format) {
                if Task.isCancelled { return }
                // Volumes from a novel opened earlier would otherwise still
                // be sitting under a manga's chapter list.
                novelVolumes = []
                novelSourceMissing = false
                let fetched = (try? await engine.mangaChapters(detail: d)) ?? []
                chapters = fetched.map {
                    MediaDetailView.MangaChapterItem(id: $0.id, number: $0.number, title: $0.title)
                }
            } else {
                novelVolumes = []
                novelSourceMissing = false
            }
            if Task.isCancelled { return }

            let relations = d.relations.map { r in
                MediaDetailView.RelationItem(
                    id: r.catalogId,
                    relationType: r.relationType,
                    title: r.title,
                    format: r.format,
                    coverURL: URL(string: r.coverImage),
                    status: r.status,
                    averageScore: r.averageScore.map(Int.init)
                )
            }

            let recommendations = d.recommendations.map { rec in
                MediaDetailView.RecommendationItem(
                    id: rec.catalogId,
                    title: rec.title,
                    format: rec.format,
                    coverURL: URL(string: rec.coverImage),
                    averageScore: rec.averageScore.map(Int.init),
                    rating: rec.rating.map(Int.init)
                )
            }

            // The page can have moved on during the fetch. Cancellation
            // covers `openDetail`'s own task; this covers a refresh that
            // was started for the page and finished after it closed.
            guard selectedMediaDetails?.id == id || loadingCatalogId == id else { return }
            self.selectedEpisodes = episodes
            if currentPlaybackCatalogId == id {
                playbackEpisodes = episodes
                playbackEpisodesCatalogId = id
                updateEpisodeNavigationState()
            }
            self.selectedMangaChapters = chapters
            // Which of them are already on disk, so a downloaded chapter
            // shows as downloaded rather than offering to fetch it again.
            self.chapterOfflineStates = [:]
            self.loadOfflineChapters()
            self.selectedRelations = relations
            self.selectedRecommendations = recommendations
            // Characters/discussions are fetched separately below and
            // weren't part of this response — falling back to whatever the
            // cache already had (rather than always clearing to empty) is
            // what stops the cast grid this function just rendered from
            // cache flashing empty the instant this fresh fetch lands.
            self.selectedCharacters = cached?.characters ?? []
            self.selectedDiscussions = cached?.discussions ?? []
            let fixture = ScreenshotFixtures.isEnabled
                ? ScreenshotFixtures.listEntry(episodeCount: (d.episodeCount ?? d.chapterCount).map(Int.init)) : nil
            let freshDetails = HeroBanner.Details(
                id: d.catalogId,
                title: d.title,
                romajiTitle: d.romajiTitle,
                bannerURL: d.bannerImage.flatMap(URL.init(string:)),
                coverURL: URL(string: d.coverImage),
                format: d.format,
                year: d.year.map(Int.init),
                studio: d.studio,
                synopsis: d.synopsis,
                genres: d.genres,
                averageScore: d.averageScore.map(Int.init),
                nextEpisodeText: nil,
                status: d.status,
                episodeCount: (d.episodeCount ?? d.chapterCount).map(Int.init),
                resumeEpisode: fixture?.resumeEpisode ?? d.resumeEpisode.map(Int.init),
                resumeSeconds: fixture.map { $0.resumeSeconds } ?? d.resumeSeconds.map(Int.init),
                prequel: d.prequel.map(Self.relation),
                sequel: d.sequel.map(Self.relation),
                listStatus: fixture?.status ?? d.listStatus,
                userScore: fixture == nil ? d.userScore : nil,
                listEntryId: d.listEntryId,
                listProgress: fixture?.progress ?? d.listProgress.map(Int.init),
                isFavourite: d.isFavourite,
                malId: d.malId,
                trailerSite: d.trailerSite,
                trailerId: d.trailerId,
                trailerThumbnail: d.trailerThumbnail,
                studios: d.studios.map {
                    HeroBanner.Details.StudioRef(id: $0.id, name: $0.name, isMain: $0.isMain)
                }
            )
            if cached == nil {
                withAnimation(.easeInOut(duration: 0.24)) {
                    self.selectedMediaDetails = freshDetails
                    self.isDetailLoading = false
                }
            } else {
                self.selectedMediaDetails = freshDetails
                self.isDetailLoading = false
            }
            await recordAniListSuccess()
            persistDetailCache(id: id, isManga: isManga)

            // Asynchronously load real Cast & Staff and Discussions from AniList if not already populated
            activeDetailExtrasTask?.cancel()
            let needsCharacters = (cached?.characters.isEmpty ?? true) || self.selectedCharacters.isEmpty
            let needsDiscussions = (cached?.discussions.isEmpty ?? true) || self.selectedDiscussions.isEmpty
            if needsCharacters || needsDiscussions {
                activeDetailExtrasTask = Task { [weak self, weak engine] in
                    guard let self, let engine, !Task.isCancelled else { return }
                    if needsCharacters {
                        if let chars = try? await engine.mediaCharacters(catalogId: id) {
                            guard !Task.isCancelled else { return }
                            let mapped = chars.map { c in
                                MediaDetailView.CharacterItem(
                                    id: c.id,
                                    name: c.name,
                                    imageURL: c.imageUrl.flatMap(URL.init(string:)),
                                    role: c.role,
                                    voiceActorName: c.voiceActorName,
                                    voiceActorImageURL: c.voiceActorImageUrl.flatMap(URL.init(string:))
                                )
                            }
                            if self.selectedMediaDetails?.id == id {
                                self.selectedCharacters = mapped
                                self.persistDetailCache(id: id, isManga: isManga)
                            }
                        }
                    }
                    if needsDiscussions {
                        guard !Task.isCancelled else { return }
                        if let disc = try? await engine.mediaDiscussions(catalogId: id) {
                            guard !Task.isCancelled else { return }
                            let mapped = disc.map { t in
                                MediaDetailView.DiscussionItem(
                                    id: t.id,
                                    title: t.title,
                                    replyCount: Int(t.replyCount),
                                    viewCount: Int(t.viewCount),
                                    authorName: t.authorName,
                                    authorAvatarURL: t.authorAvatarUrl.flatMap(URL.init(string:)),
                                    repliedAt: t.repliedAt
                                )
                            }
                            if self.selectedMediaDetails?.id == id {
                                self.selectedDiscussions = mapped
                                self.persistDetailCache(id: id, isManga: isManga)
                            }
                        }
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.isDetailLoading = false
            await recordAniListFailure(error)
            // A cached snapshot is already on screen (from the top of this
            // function) — a failed refresh shouldn't blank it out from under
            // the viewer, just quietly leave what's already showing.
            if cached == nil {
                let msg = error.localizedDescription
                errorMessage = "Could not open that title: \(msg)"
                // Roll back provisional screen so viewer isn't left on an empty zombie page
                if self.selectedMediaDetails?.id == id {
                    if let previous = self.detailHistory.popLast() {
                        self.restoredDetailTab = previous.tab
                        // Through its own catalog, like every other restore.
                        self.restore(previous)
                    } else {
                        withAnimation(.easeInOut(duration: 0.32)) {
                            self.selectedMediaDetails = nil
                        }
                    }
                }
            }
        }
    }

    /// Snapshots the detail page's current in-memory state to disk under
    /// `(id, isManga)`. Called after each piece of the page lands (initial
    /// detail, then characters, then discussions) so a cache read later gets
    /// whatever was available last time, not just what happened to be ready
    /// at the very first save.
    func persistDetailCache(id: Int64, isManga: Bool) {
        guard let details = selectedMediaDetails, details.id == id else { return }
        DetailCache.save(
            DetailCache.Snapshot(
                details: details,
                episodes: selectedEpisodes,
                mangaChapters: selectedMangaChapters,
                relations: selectedRelations,
                recommendations: selectedRecommendations,
                characters: selectedCharacters,
                discussions: selectedDiscussions
            ),
            id: id,
            isManga: isManga
        )
    }

    public func openDetail(catalogId: Int64, title: String? = nil, coverURL: URL? = nil, isManga: Bool = false) async {
        await openDetail(id: catalogId, title: title, coverURL: coverURL, isManga: isManga)
    }

    /// Speculatively warms up in-memory/disk caches for a title when hovered on desktop.
    public func prefetchDetail(id: Int64, isManga: Bool) {
        guard let engine, !isAniListDown else { return }
        if DetailCache.load(id: id, isManga: isManga) != nil { return }
        guard !activePrefetches.contains(id) else { return }
        activePrefetches.insert(id)
        Task(priority: .background) { [weak self, weak engine] in
            guard let self, let engine else { return }
            defer { self.activePrefetches.remove(id) }
            // 200ms debounce to avoid triggering on quick cursor sweeps across cards
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            _ = try? await engine.mediaDetail(catalogId: id, isManga: isManga)
        }
    }

    /// Same format check `RootView`/`MediaDetailView` already use to route
    /// play vs. read actions for the open title.
    func currentDetailIsManga() -> Bool {
        guard let format = selectedMediaDetails?.format else { return false }
        return format == "MANGA" || format == "NOVEL" || format == "ONE_SHOT"
    }

    /// Changes the signed-in user's AniList list entry for the open title —
    /// status, score, or progress, independently. Refetches the detail page
    /// afterward rather than updating local state optimistically, so what's
    /// shown is what AniList actually saved.
    public func updateListEntry(status: String? = nil, score: Double? = nil, progress: Int64? = nil) async {
        guard let engine, let details = selectedMediaDetails else { return }
        do {
            try await engine.updateListEntry(catalogId: details.id, status: status, score: score, progress: progress)
            await recordAniListSuccess()
            // Off the Up Next shelf at once when the title leaves the
            // watching list; the background re-read below confirms it.
            if let status, status != "CURRENT", status != "REPEATING" {
                upNextItems.removeAll { $0.id == details.id }
                watchingItems.removeAll { $0.id == details.id }
            }
            refreshListsAfterEdit()
            // Not `openDetail(id:)`: its "already viewing this title" guard
            // (`selectedMediaDetails?.id == id && !isDetailLoading`) always
            // matches here, since this mutation runs on the page currently
            // open — so it silently no-op'd instead of refreshing, and the
            // mark-watched checkbox (this is also what it calls) looked like
            // it did nothing after a real, slow AniList round trip.
            // `loadDetail` is the same fetch without that dedup guard.
            // `forceRefresh` because this mutation just made the cache stale
            // by definition — the freshness-window skip below exists for
            // "reopened the same title I already just saw", not this.
            await loadDetail(id: details.id, isManga: currentDetailIsManga(), forceRefresh: true)
        } catch {
            await recordAniListFailure(error)
            errorMessage = "Could not update AniList: \(error.localizedDescription)"
        }
    }

    public func toggleFavourite() async {
        guard let engine, let details = selectedMediaDetails else { return }
        let isManga = currentDetailIsManga()
        do {
            let now = try await engine.toggleFavourite(
                catalogId: details.id, isManga: isManga, currentlyFavourite: details.isFavourite)
            await recordAniListSuccess()
            PlayerLog.write("[favourite] \(details.id): was \(details.isFavourite), now \(now)")
            // Taken from the mutation's answer, not from a refetch: seven
            // presses in a row logged "was true, now true" because the
            // detail query re-read after each toggle returned the value from
            // before it. The engine patches its own cached row to the same
            // answer, so the snapshot here is what a reopen will read too.
            guard selectedMediaDetails?.id == details.id else { return }
            selectedMediaDetails?.isFavourite = now
            if var snapshot = DetailCache.load(id: details.id, isManga: isManga) {
                snapshot.details.isFavourite = now
                DetailCache.save(snapshot, id: details.id, isManga: isManga)
            }
        } catch {
            await recordAniListFailure(error)
            errorMessage = "Could not update favourite: \(error.localizedDescription)"
        }
    }

    /// Removes the open title from the signed-in user's list entirely.
    public func removeFromList() async {
        guard let engine, let details = selectedMediaDetails, let entryId = details.listEntryId else { return }
        do {
            try await engine.removeFromList(listEntryId: entryId)
            await recordAniListSuccess()
            upNextItems.removeAll { $0.id == details.id }
            watchingItems.removeAll { $0.id == details.id }
            refreshListsAfterEdit()
            // Not `openDetail(id:)` — see the identical fix on
            // `updateListEntry`: its "already viewing this title" guard
            // always matches here since this runs on the page currently
            // open, so the refresh silently no-op'd and the list-status
            // menu kept showing the removed entry's old status.
            await loadDetail(id: details.id, isManga: currentDetailIsManga(), forceRefresh: true)
        } catch {
            await recordAniListFailure(error)
            errorMessage = "Could not remove from AniList: \(error.localizedDescription)"
        }
    }

    /// The player's 85% auto-advance, which cannot go through
    /// `setEpisodeWatched`/`updateListEntry` unconditionally: both open with
    /// `guard let details = selectedMediaDetails`, and playback started from
    /// a home shelf has no detail page open at all — so bingeing from the
    /// home screen advanced the local watch registry on every episode while
    /// AniList silently never moved. With the page open this still routes
    /// through the checkbox's own path so the list updates optimistically
    /// under the viewer; without it, the entry's current state is fetched
    /// (one call, once per episode, only on the threshold crossing) and the
    /// mutation is sent directly.
    /// `contiguousOnly` refuses the write when the episode is more than one
    /// past what AniList already has. The next-episode button uses it:
    /// AniList's progress is cumulative, so sending 20 from a list sitting
    /// at 5 marks 6 to 19 watched as well. Tapping Next to skip ahead should
    /// mark the episode being left, not the fifteen it jumped over.
    func advanceAniListProgress(
        catalogId: Int64,
        episode: Int,
        contiguousOnly: Bool = false
    ) async {
        if let details = selectedMediaDetails, details.id == catalogId {
            let progress = Int(details.listProgress ?? 0)
            guard progress < episode else { return }
            guard !contiguousOnly || episode <= progress + 1 else { return }
            await setEpisodeWatched(episode, watched: true)
            return
        }
        guard let engine else { return }
        do {
            let detail = try await engine.mediaDetail(catalogId: catalogId, isManga: false)
            // Read from AniList rather than assumed 0: without the detail
            // page there is no local copy of the entry, and re-sending a
            // progress the list already passed would drag it backwards on a
            // rewatch.
            let listed = Int(detail.listProgress ?? 0)
            guard listed < episode else { return }
            guard !contiguousOnly || episode <= listed + 1 else { return }
            let (progress, status) = Self.listEntryUpdate(
                episode: episode,
                watched: true,
                episodeCount: (detail.episodeCount ?? detail.chapterCount).map(Int.init),
                listStatus: detail.listStatus
            )
            try await engine.updateListEntry(
                catalogId: catalogId,
                status: status,
                score: nil,
                progress: Int64(progress)
            )
            await recordAniListSuccess()
            refreshListsAfterEdit()
        } catch {
            await recordAniListFailure(error)
        }
    }

    /// The episode list's mark-watched checkbox. Mirrors
    /// `handleUpdateProgress` in MediaDetail.tsx: watching episode N sets
    /// progress to N; un-watching it sets progress to N-1. Unlike the web
    /// build (which re-fetches the whole title server-side just to learn the
    /// episode total), the clamp-to-total-and-complete safety net runs here
    /// against `episodeCount`, already in hand from the open detail page —
    /// covers a provider that lists one extra episode (e.g. a special
    /// counted as `total+1`) without a second round trip.
    public func setEpisodeWatched(_ episode: Int, watched: Bool) async {
        guard let details = selectedMediaDetails else { return }
        let (progress, status) = Self.listEntryUpdate(
            episode: episode,
            watched: watched,
            episodeCount: details.episodeCount,
            listStatus: details.listStatus
        )
        // Optimistic: `updateListEntry` below is a real AniList mutation
        // followed by a full re-fetch to reconcile — two sequential network
        // round trips before the checkbox would otherwise show anything.
        // Flipping locally first (same progress-cutoff rule the server uses)
        // makes the toggle feel instant; the re-fetch still lands afterward
        // and corrects this if the server's answer differs.
        selectedEpisodes = selectedEpisodes.map { ep in
            let shouldBeWatched = ep.number <= progress
            guard ep.isWatched != shouldBeWatched else { return ep }
            return MediaDetailView.EpisodeItem(
                id: ep.id,
                number: ep.number,
                title: ep.title,
                thumbnailURL: ep.thumbnailURL,
                isWatched: shouldBeWatched,
                progressPercent: ep.progressPercent,
                synopsis: ep.synopsis,
                airDate: ep.airDate,
                runtimeMinutes: ep.runtimeMinutes
            )
        }
        // An un-check has to forget the local watch record too, not just move
        // AniList's progress down. `episode_is_watched` is
        // `local_percent >= 85.0 || number <= anilist_progress`, so a history
        // row past 85% pinned the box on whatever the list said: un-checking
        // episode 10 of a title watched to 92.9% wrote `progress: 9`, AniList
        // took it, and the row snapped straight back to checked. Six clicks
        // in four seconds, all of them landing, none of them visible.
        //
        // Before the mutation, and awaited: `updateListEntry` ends in a
        // detail reload that rebuilds this list from the local history and
        // the list entry together, so a clear that lands after it is a clear
        // the viewer does not see.
        if !watched, let engine {
            let catalog = playbackCatalogForOpenDetail
            await withCheckedContinuation { continuation in
                engineIOQueue.async {
                    try? engine.clearProgressFrom(
                        catalog: catalog,
                        catalogId: details.id,
                        episodeNumber: Int64(episode)
                    )
                    continuation.resume()
                }
            }
        }
        await updateListEntry(status: status, progress: Int64(progress))
    }

    /// Backs the "More from <studio>" shelf. Returns what is already known
    /// straight away and fetches only on a miss, because the shelf asks
    /// from `onAppear` — which fires again every time it scrolls back into
    /// view, and on a studio the viewer has already opened a page for the
    /// answer is sitting in `studioWorks` from that load.
    ///
    /// The current title is not filtered out here: the cache is keyed by
    /// studio and shared by every title that studio made, so the exclusion
    /// belongs to whoever is drawing the shelf.
    public func studioWorks(studioId: Int64) async -> [MediaSummary] {
        if let cached = studioWorks[studioId] { return cached }
        guard let engine, !studioWorksInFlight.contains(studioId) else { return [] }
        studioWorksInFlight.insert(studioId)
        defer { studioWorksInFlight.remove(studioId) }
        guard let detail = try? await engine.studioDetail(studioId: studioId) else { return [] }
        studioWorks[studioId] = detail.media
        return detail.media
    }

    /// The environment value the detail page's studio buttons and shelf
    /// read, bound to this model. Built here rather than at the scene so
    /// both platforms' scenes install the same one.
    public var studioPageActions: StudioPageActions {
        StudioPageActions(
            open: { [weak self] id in self?.openStudio(id: id) },
            works: { [weak self] id in await self?.studioWorkItems(studioId: id) ?? [] }
        )
    }

    /// `studioWorks` in the shape the detail page's shelf draws.
    public func studioWorkItems(studioId: Int64) async -> [MediaDetailView.StudioWorkItem] {
        await studioWorks(studioId: studioId).map {
            MediaDetailView.StudioWorkItem(
                id: $0.catalogId,
                title: $0.title,
                coverImage: $0.coverImage,
                format: $0.format
            )
        }
    }

    static func relation(_ r: RelatedTitle) -> HeroBanner.Details.Relation {
        HeroBanner.Details.Relation(
            id: r.catalogId,
            title: r.title,
            format: r.format,
            coverURL: URL(string: r.coverImage)
        )
    }

    /// The progress/status pair a mark-watched implies. Shared by the
    /// episode list's checkbox and the player's 85% auto-advance rather than
    /// written twice: the two disagreeing is how a binge that finished a
    /// season left the list entry on CURRENT at `total`.
    static func listEntryUpdate(
        episode: Int,
        watched: Bool,
        episodeCount: Int?,
        listStatus: String?
    ) -> (progress: Int, status: String?) {
        var progress = watched ? episode : episode - 1
        var status: String?
        if let total = episodeCount, total > 0, progress >= total {
            progress = total
            status = "COMPLETED"
        } else if progress > 0, listStatus == nil || listStatus == "PLANNING" {
            status = "CURRENT"
        }
        return (progress, status)
    }
}
