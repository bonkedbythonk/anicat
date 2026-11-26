import SwiftUI

/// Single card placeholder matching MediaCard's exact poster aspect ratio (2:3)
/// and 54pt text container height, preventing layout jumps when data arrives.
public struct MediaCardSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SumiRect(cornerRadius: SumiTheme.radiusMd)
                .fill(SumiTheme.foregroundWash)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(SumiTheme.foregroundWash)
                    .frame(height: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 70, height: 10)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            .padding(.horizontal, 2)
        }
    }
}

/// Adaptive grid placeholder sharing the same column width bracket (165-200)
/// and spacing as SumiPosterGrid and SearchView grids.
public struct MediaGridSkeleton: View {
    let count: Int

    public init(count: Int = 12) {
        self.count = count
    }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165, maximum: 200), spacing: 20, alignment: .top)],
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(0..<count, id: \.self) { _ in
                MediaCardSkeleton()
            }
        }
    }
}

/// Backward compatibility alias for the grid skeleton initially introduced in LibraryView.
public typealias LibrarySkeleton = MediaGridSkeleton

/// Horizontal shelf placeholder matching mediaRow's 180pt card width and
/// header typography on Home.
public struct MediaRowSkeleton: View {
    let title: String
    let count: Int

    public init(title: String, count: Int = 6) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                // `sumiHeading`, the same as the shelf it stands in for:
                // with `.system` the placeholder header was sans and the real
                // one serif under Sakura, and the swap showed on every load.
                Text(title)
                    .font(.sumiHeading(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)

                Spacer()

                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 48, height: 11)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(0..<count, id: \.self) { _ in
                        MediaCardSkeleton()
                            .frame(width: 180)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Up next on the very first launch, before the home snapshot exists: the
/// Continue tile, its text, the New for you column and the Continue shelf,
/// at their real sizes so nothing moves when the list lands. `wide` is the
/// same switch the page uses to put New for you beside the tile.
struct UpNextSkeleton: View {
    let wide: Bool

    private func bar(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = 6) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(SumiTheme.foregroundWash)
            .frame(width: width, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            HStack(spacing: 24) {
                SumiRect(cornerRadius: SumiTheme.radiusXl)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: UpNextContinueTile.tileSize.width, height: UpNextContinueTile.tileSize.height)
                VStack(alignment: .leading, spacing: 12) {
                    bar(width: 60, height: 12)
                    bar(height: 28).frame(maxWidth: 360, alignment: .leading)
                    bar(height: 14).frame(maxWidth: 240, alignment: .leading)
                    bar(width: 200, height: 40, radius: SumiTheme.radiusLg).padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    VStack(alignment: .leading, spacing: 14) {
                        bar(width: 120, height: 16)
                        ForEach(0..<3, id: \.self) { _ in bar(height: 48) }
                    }
                    .frame(width: 240)
                }
            }
            .frame(height: UpNextContinueTile.tileSize.height)

            VStack(alignment: .leading, spacing: 12) {
                bar(width: 110, height: 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            MediaCardSkeleton().frame(width: 180)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollDisabled(true)
            }
        }
    }
}

/// Single episode placeholder matching EpisodeRow / CompactEpisodeRow height and layout.
public struct EpisodeRowSkeleton: View {
    public let isCompact: Bool

    public init(isCompact: Bool = false) {
        self.isCompact = isCompact
    }

    public var body: some View {
        if isCompact {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 32, height: 14)
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(height: 14)
                    .frame(maxWidth: 240)
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 40, height: 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SumiTheme.card.opacity(0.4))
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusMd))
        } else {
            HStack(alignment: .top, spacing: 14) {
                SumiRect(cornerRadius: SumiTheme.radiusMd)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 135, height: 76)

                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(SumiTheme.foregroundWash)
                        .frame(width: 60, height: 11)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(SumiTheme.foregroundWash)
                        .frame(height: 14)
                        .frame(maxWidth: 260, alignment: .leading)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(SumiTheme.foregroundWash)
                        .frame(height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(SumiTheme.card.opacity(0.4))
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusLg))
            .overlay(
                SumiRect(cornerRadius: SumiTheme.radiusLg)
                    .stroke(SumiTheme.border.opacity(0.4), lineWidth: 1)
            )
        }
    }
}

/// Episode list placeholder when a title's episode list is loading.
public struct EpisodeListSkeleton: View {
    public let count: Int
    public let isCompact: Bool

    public init(count: Int = 6, isCompact: Bool = false) {
        self.count = count
        self.isCompact = isCompact
    }

    public var body: some View {
        LazyVStack(spacing: isCompact ? 4 : 8) {
            ForEach(0..<count, id: \.self) { _ in
                EpisodeRowSkeleton(isCompact: isCompact)
            }
        }
    }
}

/// Multi-line synopsis placeholder.
public struct SynopsisSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(SumiTheme.foregroundWash)
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 4)
                .fill(SumiTheme.foregroundWash)
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 4)
                .fill(SumiTheme.foregroundWash)
                .frame(width: 220, height: 14)
        }
        .padding(.vertical, 4)
    }
}
