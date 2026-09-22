import SwiftUI

/// How a release list can be ordered. `.best` is the engine's own ranking
/// (title match, trusted group, swarm, dub preference), which is what the
/// auto-pick used; the other two are for a viewer who already knows what
/// they want: the healthiest swarm, or the smallest download on a slow line.
enum ReleaseSort: String, CaseIterable {
    case best, seeders, size

    var label: String {
        switch self {
        case .best: return "Best match"
        case .seeders: return "Seeders"
        case .size: return "Size"
        }
    }

    /// Stable within ties, so equal rows keep the engine's order. Unknown
    /// seeders sort below every known count, and an unknown size after every
    /// known one, whichever the order asked for: a guess is never first.
    func apply(_ items: [MediaDetailView.ReleaseCandidateItem]) -> [MediaDetailView.ReleaseCandidateItem] {
        let indexed = Array(items.enumerated())
        switch self {
        case .best:
            return items
        case .seeders:
            return indexed.sorted { a, b in
                let ka = a.element.seedersKnown ? a.element.seeders : -1
                let kb = b.element.seedersKnown ? b.element.seeders : -1
                return ka != kb ? ka > kb : a.offset < b.offset
            }.map(\.element)
        case .size:
            return indexed.sorted { a, b in
                switch (a.element.sizeBytes, b.element.sizeBytes) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }
    }
}

extension MediaDetailView.ReleaseCandidateItem {
    /// Coarse swarm health for the dot beside the count. The bands follow
    /// what the engine itself treats as viable: below 5 a release is
    /// penalised as a probably-dead swarm (`LOW_SEEDER_THRESHOLD`), and
    /// 20 and up starts in a couple of seconds on an ordinary line.
    enum Health { case good, fair, weak, unknown }

    var health: Health {
        guard seedersKnown else { return .unknown }
        if seeders >= 20 { return .good }
        if seeders >= 5 { return .fair }
        return .weak
    }

    var seedersText: String {
        guard seedersKnown else { return "seeders unknown" }
        return seeders == 1 ? "1 seeder" : "\(seeders) seeders"
    }

    var sizeText: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .binary)
    }
}

/// The line under a release name: health, seeders, size, dub. One view for
/// the player's list and the detail page's Stream Servers popover, so the
/// two cannot drift apart again (they already had once: the player had
/// "Played last time", the popover did not).
struct ReleaseStatsLine<Trailing: View>: View {
    let item: MediaDetailView.ReleaseCandidateItem
    var fontSize: CGFloat = 10.5
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(item.seedersText)
                .sumiTabularMono(size: fontSize)
                .foregroundColor(SumiTheme.muted)
            if let size = item.sizeText {
                Text("·")
                    .foregroundColor(SumiTheme.muted.opacity(0.6))
                Text(size)
                    .sumiTabularMono(size: fontSize)
                    .foregroundColor(SumiTheme.muted)
            }
            if item.isDub {
                Text("DUB")
                    .sumiTabularMono(size: fontSize - 0.5, weight: .bold)
                    .foregroundColor(SumiTheme.indigo)
            }
            trailing()
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch item.health {
        case .good: return SumiTheme.success
        case .fair: return SumiTheme.warning
        case .weak: return SumiTheme.danger
        case .unknown: return SumiTheme.muted.opacity(0.5)
        }
    }
}

extension ReleaseStatsLine where Trailing == EmptyView {
    init(item: MediaDetailView.ReleaseCandidateItem, fontSize: CGFloat = 10.5) {
        self.init(item: item, fontSize: fontSize, trailing: { EmptyView() })
    }
}

/// The three-way sort above either release list.
struct ReleaseSortPicker: View {
    @Binding var sort: ReleaseSort

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReleaseSort.allCases, id: \.self) { option in
                Button {
                    sort = option
                } label: {
                    Text(option.label)
                        .font(.system(size: 10.5, weight: sort == option ? .semibold : .regular))
                        .foregroundColor(sort == option ? SumiTheme.foreground : SumiTheme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(sort == option ? SumiTheme.foregroundWash : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sort == option ? .isSelected : [])
            }
        }
    }
}
