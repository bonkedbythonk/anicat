import SwiftUI
import AnicatCoreKit

/// The Related tab's watch order: the title and everything around it in the
/// order someone would watch them, as one line of posters with "you are
/// here" marked, then the relations that line does not include.
///
/// Built from the engine's franchise walk (`AppModel.franchise`), which
/// follows the prequel/sequel line to both ends with start dates. The
/// title's own relations are one step deep -- from Sword Art Online they
/// reached SAO II and stopped short of Alicization -- so they are only the
/// fallback when the walk fails, with years from whatever detail snapshots
/// are on disk (`DetailCache.peekFacts`).
struct WatchOrderTimeline: View {
    let details: HeroBanner.Details
    let relations: [MediaDetailView.RelationItem]
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    @State private var groups: [WatchOrder.YearGroup] = []

    private var entries: [WatchOrder.Entry] { groups.flatMap(\.entries) }

    /// Relations the line leaves out. The walk keeps to one media type and
    /// to sequels and side stories, so the manga a show adapts, a crossover
    /// or a character relation is not on it -- and before the tabs merged
    /// those were reachable from the Grid view this replaced.
    private var otherRelations: [MediaDetailView.RelationItem] {
        let onLine = Set(entries.map(\.id))
        return relations.filter { !onLine.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                SumiSectionHeader("Watch order", trailing: entries.isEmpty ? nil : "Release order · \(entries.count) entries")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(entries) { entry in
                            WatchOrderRow(entry: entry) {
                                guard !entry.isCurrent else { return }
                                onSelectMediaId?(
                                    entry.id,
                                    entry.title,
                                    entry.coverURL,
                                    AppModel.isMangaFormat(entry.format)
                                )
                            }
                        }
                    }
                    // The rail the dots sit on, behind the whole line.
                    .background(alignment: .topLeading) {
                        Rectangle()
                            .fill(SumiTheme.border)
                            .frame(height: 2)
                            .padding(.top, 5)
                            .padding(.horizontal, 6)
                    }
                    .padding(.bottom, 4)
                }
                .backSwipeExempt()
            }

            if !otherRelations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SumiSectionHeader("Also related", trailing: "\(otherRelations.count)")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 24)], spacing: 0) {
                        ForEach(otherRelations) { rel in
                            MediaDetailView.RelatedMediaCard(relation: rel) {
                                onSelectMediaId?(rel.id, rel.title, rel.coverURL, AppModel.isMangaFormat(rel.format))
                            }
                        }
                    }
                }
            }
        }
        // Reading a snapshot per relation is file I/O, so it stays off the
        // body and out of the main actor's way; the timeline draws empty
        // for the frame it takes.
        //
        // Keyed on the relation count as well as the title: the page
        // renders from a cached snapshot first and the fresh fetch fills
        // `relations` afterwards. On the id alone the Grid picked those up
        // (it reads the array in its own body) and the timeline kept
        // showing the current title by itself.
        .task(id: "\(details.id)-\(relations.count)") {
            if details.mediaCatalog == .anilist,
               let franchise = await AppModel.shared?.franchise(id: details.id),
               let entries = Self.entries(details: details, franchise: franchise) {
                groups = WatchOrder.grouped(entries)
                return
            }
            let entries = await Self.entries(details: details, relations: relations)
            groups = WatchOrder.grouped(entries)
        }
    }

    /// The walk's entries in watch order. The main line carries no relation
    /// type of its own, so each entry is placed before or after the open
    /// title by start date, which is what `WatchOrder.sort` ranks on. Nil if
    /// the walk did not include the open title, which would leave the rail
    /// with no "you are here".
    private static func entries(
        details: HeroBanner.Details,
        franchise: [FfiFranchiseEntry]
    ) -> [WatchOrder.Entry]? {
        guard let here = franchise.first(where: { $0.catalogId == details.id }) else { return nil }
        func started(_ entry: FfiFranchiseEntry) -> Int? {
            entry.year.map { Int($0) * 12 + Int(entry.month ?? 0) }
        }
        let hereStarted = started(here)
        let current = WatchOrder.Entry(
            id: details.id,
            title: details.title,
            relationType: nil,
            format: details.format,
            coverURL: details.coverURL,
            year: here.year.map(Int.init) ?? details.year,
            season: here.season,
            episodeCount: details.episodeCount,
            listStatus: details.listStatus,
            isCurrent: true
        )
        let others = franchise.filter { $0.catalogId != details.id }.map { entry -> WatchOrder.Entry in
            let placed: String
            if let aside = entry.aside {
                placed = aside
            } else if let start = started(entry), let hereStart = hereStarted, start < hereStart {
                placed = "PREQUEL"
            } else {
                placed = "SEQUEL"
            }
            return WatchOrder.Entry(
                id: entry.catalogId,
                title: entry.title,
                relationType: placed,
                format: entry.format,
                coverURL: URL(string: entry.coverImage),
                year: entry.year.map(Int.init),
                season: entry.season,
                episodeCount: entry.episodes.map(Int.init),
                listStatus: entry.listStatus
            )
        }
        return WatchOrder.sort(relations: others, current: current)
    }

    private static func entries(
        details: HeroBanner.Details,
        relations: [MediaDetailView.RelationItem]
    ) async -> [WatchOrder.Entry] {
        await Task.detached(priority: .userInitiated) {
            let current = WatchOrder.Entry(
                id: details.id,
                title: details.title,
                relationType: nil,
                format: details.format,
                coverURL: details.coverURL,
                year: details.year,
                episodeCount: details.episodeCount,
                listStatus: details.listStatus,
                isCurrent: true
            )
            let mapped = relations.map { relation -> WatchOrder.Entry in
                let isManga = AppModel.isMangaFormat(relation.format)
                // A title can be cached under either kind — the detail
                // loader falls back to the opposite one when AniList
                // disagrees with the format — so a miss is retried the
                // other way round before giving up.
                let facts = DetailCache.peekFacts(id: relation.id, isManga: isManga)
                    ?? DetailCache.peekFacts(id: relation.id, isManga: !isManga)
                return WatchOrder.Entry(
                    id: relation.id,
                    title: relation.title,
                    relationType: relation.relationType,
                    format: relation.format,
                    coverURL: relation.coverURL,
                    year: facts?.year,
                    episodeCount: facts?.episodeCount,
                    listStatus: facts?.listStatus
                )
            }
            return WatchOrder.sort(relations: mapped, current: current)
        }.value
    }
}

/// One title on the line: its dot, its poster, its name and where the
/// viewer stands with it.
struct WatchOrderRow: View {
    let entry: WatchOrder.Entry
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                dot
                Color.clear
                    .frame(width: 100, height: 150)
                    .overlay {
                        CachedAsyncImage(url: entry.coverURL, maxPixelSize: 300) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                    }
                    .clipped()
                    .clipShape(SumiRect(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        SumiRect(cornerRadius: SumiTheme.radiusMd)
                            .stroke(entry.isCurrent ? SumiTheme.indigo : SumiTheme.border, lineWidth: entry.isCurrent ? 2 : 1)
                    )
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isHovered && !entry.isCurrent ? SumiTheme.indigo : SumiTheme.foreground)
                    .lineLimit(2, reservesSpace: true)
                Text(stateLabel)
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(stateColor)
                    .lineLimit(2)
            }
            .frame(width: 140, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .disabled(entry.isCurrent)
        .stableHover { isHovered = $0 }
        .animation(.sumi(.pop), value: isHovered)
    }

    private var isCompleted: Bool { entry.listStatus == "COMPLETED" }

    /// Filled green once finished, ringed in the accent where the viewer
    /// is, an empty ring for the rest.
    private var dot: some View {
        ZStack {
            Circle().fill(isCompleted ? SumiTheme.success : SumiTheme.background)
            Circle().strokeBorder(
                isCompleted ? SumiTheme.success : (entry.isCurrent ? SumiTheme.indigo : SumiTheme.muted),
                lineWidth: 2
            )
        }
        .frame(width: 12, height: 12)
    }

    private var stateLabel: String {
        if entry.isCurrent { return "You are here" }
        var parts: [String] = []
        if let status = entry.listStatus {
            parts.append(MediaCard.displayRelation(status))
        } else if let type = entry.relationType {
            parts.append(MediaCard.displayRelation(type))
        }
        if let format = entry.format {
            parts.append(MediaCard.displayFormat(format))
        }
        if let count = entry.episodeCount, count > 0 {
            parts.append("\(count) eps")
        }
        return parts.joined(separator: " · ")
    }

    private var stateColor: Color {
        if entry.isCurrent { return SumiTheme.indigo }
        return isCompleted ? SumiTheme.success : SumiTheme.muted
    }
}
