import SwiftUI
import AnicatCoreKit

/// "Stream Servers" popover content: every release the indexers found for
/// this episode, best (highest seeders) first, so a stalled auto-pick can be
/// swapped for a healthier one without leaving the episode list.
struct ServerPickerView: View {
    let isLoading: Bool
    let candidates: [MediaDetailView.ReleaseCandidateItem]
    let onSelect: (String) -> Void
    @State private var sort: ReleaseSort = .best

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STREAM SERVERS")
                .sumiTabularMono(size: 10.5, weight: .semibold)
                .foregroundColor(SumiTheme.muted)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching indexers…")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }
                .padding(14)
            } else if candidates.isEmpty {
                Text("No releases found.")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                    .padding(14)
            } else {
                ReleaseSortPicker(sort: $sort)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
                let sorted = sort.apply(candidates)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sorted) { candidate in
                            Button {
                                onSelect(candidate.name)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        // Real release names routinely run
                                        // 80-100+ characters (group tag,
                                        // full title, resolution, codec,
                                        // audio track) — a 2-line cap at
                                        // 11pt in a 340pt-wide popover
                                        // truncated most of them into
                                        // unreadable mush. Uncapped at a
                                        // wider column reads as an actual
                                        // release name again.
                                        Text(candidate.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(SumiTheme.foreground)
                                            // Uncapped, this let one very
                                            // long release name (fansub
                                            // group + full title + codec
                                            // tags) wrap 3-4 lines and eat
                                            // most of the popover's height
                                            // by itself, so only one row
                                            // fit on screen at a time. The
                                            // wider 460pt column already
                                            // fixed the "unreadably tiny"
                                            // complaint; 2 lines is enough
                                            // to actually read a name at
                                            // that width.
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        ReleaseStatsLine(item: candidate)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(SumiTheme.muted.opacity(0.5))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)

                            if candidate.id != sorted.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                // A row is about 62pt (a name on up to two 12pt lines, the
                // seeders line, 9pt of padding either side, a divider), and
                // `list_candidates` does not truncate — a popular episode
                // comes back with dozens. At 380 that was six rows on
                // screen, so picking a healthier release meant scrolling a
                // list whose shape you could not see; 560 shows nine and
                // still leaves room above and below the anchored row on a
                // laptop display.
                //
                // A height, not a `maxHeight`: a popover sizes itself to its
                // content's ideal size, and a ScrollView's ideal height is
                // next to nothing, so under `maxHeight` the list collapsed to
                // one clipped row (six releases found, one half-visible name
                // and no seeders line).
                .frame(height: min(CGFloat(candidates.count) * 62, 560))
            }
        }
        .frame(width: 460)
        .background(SumiTheme.card)
    }
}

// MARK: - Studio navigation
