import SwiftUI

public enum PickerMood: String, CaseIterable, Identifiable, Sendable {
    case `continue` = "Continue"
    case somethingNew = "Something new"

    public var id: String { rawValue }
}

public struct PickerCandidate: Identifiable, Equatable {
    public let item: MediaCard.Item
    public let score: Double
    public let reasons: [String]

    public var id: Int64 { item.id }

    public init(item: MediaCard.Item, score: Double, reasons: [String]) {
        self.item = item
        self.score = score
        self.reasons = reasons
    }
}

public struct PickerSheet: View {
    @Bindable public var model: AppModel
    @Binding public var isPresented: Bool
    public var onCommit: ((MediaCard.Item) -> Void)?

    @State private var mood: PickerMood = .continue
    @State private var filterShort = false
    @State private var filterComfy = false
    @State private var filterIntense = false
    @State private var cursor = 0

    public init(
        model: AppModel,
        isPresented: Binding<Bool>,
        onCommit: ((MediaCard.Item) -> Void)? = nil
    ) {
        self.model = model
        self._isPresented = isPresented
        self.onCommit = onCommit
    }

    private var candidates: [PickerCandidate] {
        Self.scoreCandidates(
            watching: model.watchingItems,
            upNext: model.upNextItems,
            planning: model.planningItems,
            trending: model.trendingItems,
            smartPicks: model.smartPicks,
            mood: mood,
            filterShort: filterShort,
            filterComfy: filterComfy,
            filterIntense: filterIntense
        )
    }

    private var currentPick: PickerCandidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates[cursor % candidates.count]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TONIGHT'S PICK")
                    .sumiTabularMono(size: 11.5, weight: .medium)
                    .foregroundColor(SumiTheme.muted)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.muted)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
            .padding(.bottom, 16)

            if let pick = currentPick {
                HStack(alignment: .top, spacing: 18) {
                    Button(action: { commit(pick.item) }) {
                        ZStack {
                            // `CachedAsyncImage`, not `AsyncImage`: the
                            // latter decodes the full cover for a 140pt slot.
                            CachedAsyncImage(url: pick.item.coverImageURL, maxPixelSize: 420) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(SumiTheme.card)
                            }
                        }
                        .frame(width: 140, height: 210)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(pick.item.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(2)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            if mood == .continue {
                                let prog = pick.item.progress ?? 0
                                let total = pick.item.totalEpisodesOrChapters.map { String($0) } ?? "?"
                                Text("EP \(prog + 1) / \(total)")
                                    .sumiTabularMono(size: 11)
                                    .foregroundColor(SumiTheme.muted)
                            }
                            if let firstReason = pick.reasons.first {
                                Text(firstReason)
                                    .font(.system(size: 12))
                                    .foregroundColor(SumiTheme.indigo)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 6)

                        if pick.reasons.count > 1 {
                            Text("Also: " + pick.reasons.dropFirst().prefix(2).joined(separator: "; ") + ".")
                                .font(.system(size: 12))
                                .foregroundColor(SumiTheme.foreground.opacity(0.6))
                                .lineLimit(2)
                                .padding(.top, 6)
                        }

                        Spacer(minLength: 14)

                        filterChipsRow

                        HStack(spacing: 10) {
                            Button(action: { commit(pick.item) }) {
                                Text("Watch this")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(SumiTheme.background)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(SumiTheme.indigo)
                                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)

                            Button(action: {
                                withAnimation(.smooth) {
                                    cursor += 1
                                }
                            }) {
                                Text("Show another")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                            .stroke(SumiTheme.border, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                        }
                        .padding(.top, 14)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .animation(.smooth, value: pick.id)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Text("Nothing matches those filters")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SumiTheme.muted)

                    filterChipsRow
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 210)
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(SumiTheme.background)
    }

    private var filterChipsRow: some View {
        // Wraps rather than compresses. In an `HStack` the five chips were
        // squeezed at a 1080pt window until their labels broke mid-word --
        // "Continu e", "Somethi ng new", "Intens e" -- because a `Text` with
        // no line limit gives up its width before its line count.
        SumiWrapHStack(spacing: 6, lineSpacing: 6) {
            PickerChip(title: "Continue", isActive: mood == .continue) {
                withAnimation(.smooth) {
                    mood = .continue
                    cursor = 0
                }
            }
            PickerChip(title: "Something new", isActive: mood == .somethingNew) {
                withAnimation(.smooth) {
                    mood = .somethingNew
                    cursor = 0
                }
            }
            PickerChip(title: "Short", isActive: filterShort) {
                withAnimation(.smooth) {
                    filterShort.toggle()
                    cursor = 0
                }
            }
            PickerChip(title: "Comfy", isActive: filterComfy) {
                withAnimation(.smooth) {
                    filterComfy.toggle()
                    cursor = 0
                }
            }
            PickerChip(title: "Intense", isActive: filterIntense) {
                withAnimation(.smooth) {
                    filterIntense.toggle()
                    cursor = 0
                }
            }
        }
    }

    private func commit(_ item: MediaCard.Item) {
        isPresented = false
        if let onCommit {
            onCommit(item)
        } else {
            Task { await model.openDetail(id: item.id, isManga: item.isManga) }
        }
    }

    public nonisolated static func scoreCandidates(
        watching: [MediaCard.Item] = [],
        upNext: [UpNextQueueView.QueueEntry] = [],
        planning: [MediaCard.Item] = [],
        trending: [MediaCard.Item] = [],
        smartPicks: [MediaCard.Item] = [],
        mood: PickerMood,
        filterShort: Bool = false,
        filterComfy: Bool = false,
        filterIntense: Bool = false,
        currentHour: Int = Calendar.current.component(.hour, from: Date()),
        jitterRange: ClosedRange<Double>? = 0...6
    ) -> [PickerCandidate] {
        let isLateNight = currentHour >= 22 || currentHour < 4
        let isEvening = currentHour >= 20 || currentHour < 4

        var pool: [MediaCard.Item]
        var planningIds = Set<Int64>()

        switch mood {
        case .continue:
            let upNextById = Dictionary(upNext.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            pool = watching.map { item in
                if let entry = upNextById[item.id] {
                    return MediaCard.Item(
                        id: item.id,
                        title: item.title,
                        coverImageURL: item.coverImageURL ?? entry.thumbnailURL,
                        isManga: item.isManga || (entry.unit == "CH"),
                        score: item.score,
                        progress: item.progress ?? max(0, entry.nextEpisodeOrChapter - 1),
                        totalEpisodesOrChapters: item.totalEpisodesOrChapters ?? (entry.totalCount > 0 ? entry.totalCount : nil),
                        hasNewEpisode: item.hasNewEpisode || entry.hasNewEpisode,
                        playlistReason: item.playlistReason
                    )
                }
                return item
            }
            let watchingIds = Set(watching.map(\.id))
            for entry in upNext where !watchingIds.contains(entry.id) {
                let progress = max(0, entry.nextEpisodeOrChapter - 1)
                let total = entry.totalCount > 0 ? entry.totalCount : nil
                pool.append(
                    MediaCard.Item(
                        id: entry.id,
                        title: entry.title,
                        coverImageURL: entry.thumbnailURL,
                        isManga: entry.unit == "CH",
                        score: nil,
                        progress: progress,
                        totalEpisodesOrChapters: total,
                        hasNewEpisode: entry.hasNewEpisode
                    )
                )
            }

        case .somethingNew:
            let watchingIds = Set(watching.map(\.id)).union(Set(upNext.map(\.id)))
            let planningFiltered = planning.filter { !watchingIds.contains($0.id) }
            planningIds = Set(planningFiltered.map(\.id))
            let fill = trending.filter { !planningIds.contains($0.id) && !watchingIds.contains($0.id) }
            pool = planningFiltered + fill
            if pool.isEmpty {
                pool = smartPicks.filter { !watchingIds.contains($0.id) }
            }
        }

        var scored: [PickerCandidate] = []

        for item in pool {
            let progress = item.progress ?? 0
            let total = item.totalEpisodesOrChapters ?? 0
            let remaining = total > 0 ? total - progress : nil

            switch mood {
            case .continue:
                if let rem = remaining, rem <= 0 && total > 0 {
                    continue
                }

                if filterShort && !((remaining != nil && remaining! <= 3) || (total > 0 && total <= 13)) {
                    continue
                }
                if filterComfy && !((remaining == nil || remaining! <= 12) && (total == 0 || total <= 26)) {
                    continue
                }
                if filterIntense && !((remaining != nil && remaining! > 12) || total > 26 || total == 0) {
                    continue
                }

                var score: Double = 0
                var reasons: [String] = []

                if item.hasNewEpisode {
                    score += 25
                    reasons.append("a new episode is out")
                }
                if let rem = remaining, rem > 0, rem <= 2 {
                    score += 30
                    reasons.append("only \(rem) episode\(rem == 1 ? "" : "s") left — you could finish it")
                } else if let rem = remaining, rem > 0, rem <= 4 {
                    score += 18
                    reasons.append("only \(rem) episodes left")
                }
                if let userScore = item.score, userScore >= 80 {
                    score += min(20.0, Double(userScore) / 5.0)
                    reasons.append("it's one of your highest-rated shows")
                }
                if (filterShort || isLateNight || isEvening) && ((remaining != nil && remaining! <= 3) || (total > 0 && total <= 13)) {
                    score += 8
                    reasons.append("short episodes suit a late night")
                }

                if reasons.isEmpty {
                    if let rem = remaining, rem > 0 {
                        reasons.append("\(rem) episode\(rem == 1 ? "" : "s") remaining")
                    } else if progress > 0 {
                        reasons.append("continue from episode \(progress + 1)")
                    } else {
                        reasons.append("in your watching queue")
                    }
                }

                if let range = jitterRange {
                    score += Double.random(in: range)
                }

                var dedupedReasons: [String] = []
                var seen = Set<String>()
                for r in reasons where seen.insert(r).inserted {
                    dedupedReasons.append(r)
                }

                scored.append(PickerCandidate(item: item, score: score, reasons: dedupedReasons))

            case .somethingNew:
                if filterShort && !(total > 0 && total <= 13) {
                    continue
                }
                if filterComfy && !(total == 0 || total <= 26) {
                    continue
                }
                if filterIntense && !(total == 0 || total > 24) {
                    continue
                }

                var score: Double = 0
                var reasons: [String] = []

                if let avg = item.score, avg > 0 {
                    score += Double(avg) / 4.0
                    if avg >= 80 {
                        reasons.append("rated \(avg)% on AniList")
                    } else if avg >= 70 {
                        reasons.append("popular with great reviews")
                    }
                }
                if let playlistReason = item.playlistReason, !playlistReason.isEmpty {
                    reasons.append(playlistReason)
                }
                if planningIds.contains(item.id) {
                    score += 15
                    reasons.append("from your planning list")
                } else {
                    reasons.append("trending right now")
                }
                if (filterShort || isLateNight || isEvening) && (total > 0 && total <= 13) {
                    score += 6
                    reasons.append("short format suits a late night")
                }

                if reasons.isEmpty {
                    reasons.append("something fresh to dive into")
                }

                if let range = jitterRange {
                    score += Double.random(in: range)
                }

                var dedupedReasons: [String] = []
                var seen = Set<String>()
                for r in reasons where seen.insert(r).inserted {
                    dedupedReasons.append(r)
                }

                scored.append(PickerCandidate(item: item, score: score, reasons: dedupedReasons))
            }
        }

        return scored.sorted { $0.score > $1.score }
    }
}

private struct PickerChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                // Sans, not the tabular-mono face: these are words, and mono
                // is for figures. Fixed so the label sets the chip's width
                // rather than the other way round.
                .font(.sumiSans(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isActive ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.55))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(isActive ? SumiTheme.indigo.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isActive ? Color.clear : SumiTheme.border, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.sumiPressable)
        .animation(.snappy, value: isActive)
    }
}
