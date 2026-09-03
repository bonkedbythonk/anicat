import SwiftUI

public struct DashboardView: View {
    public enum NavigationItem: String, CaseIterable, Identifiable {
        case upNext = "Up Next"
        case schedule = "Schedule"
        case library = "Library"
        case manga = "Manga"
        case search = "Search"
        case history = "History"
        case settings = "Settings"

        public var id: String { rawValue }

        public var iconName: String {
            switch self {
            case .upNext: return "play.square.stack"
            case .schedule: return "calendar"
            case .library: return "square.grid.2x2"
            case .manga: return "book"
            case .search: return "magnifyingglass"
            case .history: return "clock"
            case .settings: return "gearshape"
            }
        }
    }

    public let upNextItems: [UpNextQueueView.QueueEntry]
    public let watchingItems: [MediaCard.Item]
    public let trendingItems: [MediaCard.Item]
    public let seasonalItems: [MediaCard.Item]
    
    public let onSelectQueueEntry: (UpNextQueueView.QueueEntry) -> Void
    public let onPlayQueueEntry: (UpNextQueueView.QueueEntry) -> Void
    public let onSelectMedia: (MediaCard.Item) -> Void
    public let onPickForMe: () -> Void

    @State private var selectedNavItem: NavigationItem = .upNext
    @State private var searchQuery: String = ""

    public init(
        upNextItems: [UpNextQueueView.QueueEntry] = [],
        watchingItems: [MediaCard.Item] = [],
        trendingItems: [MediaCard.Item] = [],
        seasonalItems: [MediaCard.Item] = [],
        onSelectQueueEntry: @escaping (UpNextQueueView.QueueEntry) -> Void = { _ in },
        onPlayQueueEntry: @escaping (UpNextQueueView.QueueEntry) -> Void = { _ in },
        onSelectMedia: @escaping (MediaCard.Item) -> Void = { _ in },
        onPickForMe: @escaping () -> Void = {}
    ) {
        self.upNextItems = upNextItems
        self.watchingItems = watchingItems
        self.trendingItems = trendingItems
        self.seasonalItems = seasonalItems
        self.onSelectQueueEntry = onSelectQueueEntry
        self.onPlayQueueEntry = onPlayQueueEntry
        self.onSelectMedia = onSelectMedia
        self.onPickForMe = onPickForMe
    }

    public var body: some View {
        NavigationSplitView {
            // Sidebar Navigation (Sumi Ledger Ink)
            sidebarView
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            // Main Content Area
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 32) {
                    // Up Next Section Header
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Up Next")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(SumiTheme.foreground)

                                if !upNextItems.isEmpty {
                                    Text("\(upNextItems.count) IN PROGRESS")
                                        .sumiTabularMono(size: 11, weight: .medium)
                                        .foregroundColor(SumiTheme.muted)
                                }
                            }

                            Spacer()

                            // "Pick for me" Random Episode Selector
                            Button(action: onPickForMe) {
                                HStack(spacing: 6) {
                                    Image(systemName: "dice")
                                        .font(.system(size: 13))
                                    Text("Pick for me")
                                        .font(.system(size: 12.5, weight: .medium))
                                }
                                .foregroundColor(SumiTheme.foreground.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(SumiTheme.card)
                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                                .overlay(
                                    RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                        .stroke(SumiTheme.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        // Up Next Queue Container
                        if !upNextItems.isEmpty {
                            UpNextQueueView(
                                items: upNextItems,
                                onSelect: onSelectQueueEntry,
                                onPlay: onPlayQueueEntry
                            )
                        }
                    }

                    // Watching Row
                    if !watchingItems.isEmpty {
                        mediaRow(title: "Watching", count: watchingItems.count, items: watchingItems)
                    }

                    // Trending Row
                    if !trendingItems.isEmpty {
                        mediaRow(title: "Trending Now", count: trendingItems.count, items: trendingItems)
                    }

                    // Seasonal Highlights Row
                    if !seasonalItems.isEmpty {
                        mediaRow(title: "Seasonal Highlights", count: seasonalItems.count, items: seasonalItems)
                    }
                }
                .padding(SumiTheme.spaceLg)
            }
            .background(SumiTheme.background)
        }
    }

    // MARK: - Sidebar View
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Category: Library
            VStack(alignment: .leading, spacing: 4) {
                Text("LIBRARY")
                    .sumiTabularMono(size: 10, weight: .semibold)
                    .foregroundColor(SumiTheme.muted.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                sidebarButton(.upNext)
                sidebarButton(.schedule)
                sidebarButton(.library)
                sidebarButton(.manga)
                sidebarButton(.search)
                sidebarButton(.history)
            }

            // Category: System
            VStack(alignment: .leading, spacing: 4) {
                Text("SYSTEM")
                    .sumiTabularMono(size: 10, weight: .semibold)
                    .foregroundColor(SumiTheme.muted.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                sidebarButton(.settings)
            }

            Spacer()

            // Search Bar at Bottom (⌘K)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                
                Text("Search anything")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                
                Spacer()

                Text("⌘K")
                    .sumiTabularMono(size: 10)
                    .foregroundColor(SumiTheme.muted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SumiTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .padding(12)
        }
        .background(SumiTheme.card)
    }

    private func sidebarButton(_ item: NavigationItem) -> some View {
        Button(action: { selectedNavItem = item }) {
            HStack(spacing: 10) {
                Image(systemName: item.iconName)
                    .font(.system(size: 13))
                    .foregroundColor(selectedNavItem == item ? SumiTheme.indigo : SumiTheme.muted)
                    .frame(width: 18)

                Text(item.rawValue)
                    .font(.system(size: 13, weight: selectedNavItem == item ? .semibold : .regular))
                    .foregroundColor(selectedNavItem == item ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.75))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(selectedNavItem == item ? SumiTheme.background : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                    .stroke(selectedNavItem == item ? SumiTheme.border : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: - Horizontal Media Row
    private func mediaRow(title: String, count: Int, items: [MediaCard.Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(SumiTheme.foreground)

                Spacer()

                Text("\(count) SHOWS")
                    .sumiTabularMono(size: 10.5)
                    .foregroundColor(SumiTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        MediaCard(item: item) {
                            onSelectMedia(item)
                        }
                        .frame(width: 165)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
