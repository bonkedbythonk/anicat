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

    var body: some View {
        ScrollView {
            // `maxWidth: .infinity` is load-bearing, not cosmetic: without it
            // the hero's banner sets the column's width from its own intrinsic
            // size (a 1900pt-wide image), and every row below it centred on
            // that instead of the screen — the page rendered with its left
            // half off the display.
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
                        Task { await model.playSelectedEpisode(episode.number) }
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(SumiTheme.border)
                }
            }
        }
    }

    @ViewBuilder
    private func about(_ details: HeroBanner.Details) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let synopsis = details.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: 14))
                    .foregroundStyle(SumiTheme.foreground)
            }
            if !details.genres.isEmpty {
                Text(details.genres.joined(separator: " · "))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(SumiTheme.muted)
            }
            if let studio = details.studio {
                Text(studio.uppercased())
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(SumiTheme.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
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
                        .frame(height: 190)
                        .overlay {
                            CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 900) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                SumiTheme.card
                            }
                        }
                        .clipped()

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
