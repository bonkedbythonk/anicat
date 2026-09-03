import SwiftUI

public struct MediaCard: View {
    public struct Item: Identifiable, Sendable {
        public let id: Int64
        public let title: String
        public let coverImageURL: URL?
        public let isManga: Bool
        public let score: Int?
        public let progress: Int?
        public let totalEpisodesOrChapters: Int?
        public let hasNewEpisode: Bool
        public let playlistReason: String?
        
        public init(
            id: Int64,
            title: String,
            coverImageURL: URL?,
            isManga: Bool = false,
            score: Int? = nil,
            progress: Int? = nil,
            totalEpisodesOrChapters: Int? = nil,
            hasNewEpisode: Bool = false,
            playlistReason: String? = nil
        ) {
            self.id = id
            self.title = title
            self.coverImageURL = coverImageURL
            self.isManga = isManga
            self.score = score
            self.progress = progress
            self.totalEpisodesOrChapters = totalEpisodesOrChapters
            self.hasNewEpisode = hasNewEpisode
            self.playlistReason = playlistReason
        }
    }

    public let item: Item
    public let onSelect: () -> Void
    
    @State private var isHovered = false

    public init(item: Item, onSelect: @escaping () -> Void) {
        self.item = item
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                // Poster Image Container (2:3 Aspect Ratio)
                // `Color.clear` is the thing that carries the 2:3 ratio, and
                // everything else rides in an overlay on top of it. Putting
                // the ratio on a shape that also had to host a `.fill`-mode
                // image let the image negotiate its own size back up the
                // stack, so posters in one shelf came out a few points apart
                // and no two cards below them lined up.
                ZStack(alignment: .bottom) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: item.coverImageURL) { phase in
                                switch phase {
                                case .empty:
                                    Rectangle()
                                        .fill(SumiTheme.card)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .scaleEffect(isHovered ? 1.03 : 1.0)
                                        .animation(.easeOut(duration: 0.3), value: isHovered)
                                case .failure:
                                    Rectangle()
                                        .fill(SumiTheme.card)
                                        .overlay(
                                            Image(systemName: "photo")
                                                .font(.system(size: 24))
                                                .foregroundColor(SumiTheme.muted)
                                        )
                                @unknown default:
                                    Rectangle().fill(SumiTheme.card)
                                }
                            }
                        }
                        .background(SumiTheme.card)
                        .clipped()

                    // Hover Dim Overlay with Centered Action Button
                    ZStack {
                        Color.black.opacity(isHovered ? 0.5 : 0.0)
                        
                        if isHovered {
                            // `.glass-button`: the surface ink with a hairline
                            // inset, not a white wash. Nothing in this skin
                            // emits light.
                            Image(systemName: item.isManga ? "book.fill" : "chevron.right")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(SumiTheme.foreground)
                                .frame(width: 48, height: 48)
                                .background(SumiTheme.card)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(SumiTheme.border, lineWidth: 1))
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isHovered)

                    // `.poster-tick` (index.css:549): 3px, an accent fill over a
                    // black 45% track. The track is what makes it legible on a
                    // bright poster — the fill alone vanishes into pale art.
                    if let progress = item.progress, let total = item.totalEpisodesOrChapters, total > 0 {
                        let pct = CGFloat(progress) / CGFloat(total)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.black.opacity(0.45))
                                Rectangle()
                                    .fill(SumiTheme.indigo)
                                    .frame(width: geo.size.width * min(max(pct, 0), 1))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )

                // Card Info: Clean Typography, Art carries the card
                VStack(alignment: .leading, spacing: 4) {
                    // Two lines of `leading-tight` 14px, always. `line-clamp-2`
                    // reserves the space on the web whether or not the title
                    // uses it; SwiftUI collapses to the text it has, so a
                    // one-line title made its card shorter than its neighbours
                    // and the metadata rows across a shelf never lined up.
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(2)
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)

                    HStack(spacing: 6) {
                        if let score = item.score, score > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(SumiTheme.muted)
                                Text("\(score)%")
                            }
                        }

                        if let progress = item.progress {
                            if item.hasNewEpisode {
                                Text("Ep \(progress + 1) out")
                                    .foregroundColor(SumiTheme.indigo)
                                    .fontWeight(.semibold)
                            } else {
                                let totalStr = item.totalEpisodesOrChapters.map { String($0) } ?? "?"
                                Text("\(progress)/\(totalStr)")
                            }
                        } else if let reason = item.playlistReason {
                            Text(reason)
                                .lineLimit(1)
                        }

                        // A card with no score, no list entry and no playlist
                        // reason has nothing in this row at all, and an empty
                        // `HStack` is zero-height however large a `minHeight`
                        // is asked of it. In a shelf that only cost a few
                        // points; in the search grid the difference compounds
                        // down every row. A hair space keeps the line box.
                        Text("\u{200A}")
                    }
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
                    // The web's metadata `<p>` occupies its line height even
                    // with nothing in it. A title with no score and no list
                    // entry otherwise collapsed this row away and made its
                    // card shorter than the ones beside it.
                    .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }
}
