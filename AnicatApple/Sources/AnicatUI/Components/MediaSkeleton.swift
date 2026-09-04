import SwiftUI

/// Single card placeholder matching MediaCard's exact poster aspect ratio (2:3)
/// and 54pt text container height, preventing layout jumps when data arrives.
public struct MediaCardSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
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
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
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
