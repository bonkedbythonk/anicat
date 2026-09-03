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
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .fill(SumiTheme.card)
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
                                    Image(systemName: "photo")
                                        .font(.system(size: 24))
                                        .foregroundColor(SumiTheme.muted)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))

                    // Hover Dim Overlay with Centered Action Button
                    ZStack {
                        Color.black.opacity(isHovered ? 0.5 : 0.0)
                        
                        if isHovered {
                            Image(systemName: item.isManga ? "book.fill" : "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isHovered)

                    // Thin Progress Tick at the bottom
                    if let progress = item.progress, let total = item.totalEpisodesOrChapters, total > 0 {
                        let pct = CGFloat(progress) / CGFloat(total)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.black.opacity(0.6))
                                Rectangle()
                                    .fill(SumiTheme.indigo)
                                    .frame(width: geo.size.width * min(max(pct, 0), 1))
                            }
                        }
                        .frame(height: 2.5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )

                // Card Info: Clean Typography, Art carries the card
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if let score = item.score, score > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
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
                    }
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
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
