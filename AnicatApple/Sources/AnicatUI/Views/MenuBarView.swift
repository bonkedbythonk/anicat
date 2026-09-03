import SwiftUI
import AnicatCoreKit

public struct MenuBarView: View {
    public struct AiringTodayItem: Identifiable, Sendable {
        public let id: Int64
        public let title: String
        public let episodeNumber: Int
        public let countdownText: String

        public init(id: Int64, title: String, episodeNumber: Int, countdownText: String) {
            self.id = id
            self.title = title
            self.episodeNumber = episodeNumber
            self.countdownText = countdownText
        }
    }

    public let lastWatchedTitle: String?
    public let lastWatchedEpisode: Int?
    public let lastWatchedThumbnailURL: URL?
    public let airingItems: [AiringTodayItem]
    
    public let onResumeLastWatched: () -> Void
    public let onOpenMainApp: () -> Void
    public let onQuit: () -> Void

    public init(
        lastWatchedTitle: String? = nil,
        lastWatchedEpisode: Int? = nil,
        lastWatchedThumbnailURL: URL? = nil,
        airingItems: [AiringTodayItem] = [],
        onResumeLastWatched: @escaping () -> Void = {},
        onOpenMainApp: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.lastWatchedTitle = lastWatchedTitle
        self.lastWatchedEpisode = lastWatchedEpisode
        self.lastWatchedThumbnailURL = lastWatchedThumbnailURL
        self.airingItems = airingItems
        self.onResumeLastWatched = onResumeLastWatched
        self.onOpenMainApp = onOpenMainApp
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "cat.fill")
                        .foregroundColor(SumiTheme.indigo)
                    Text("ANICAT")
                        .sumiTabularMono(size: 12, weight: .bold)
                        .foregroundColor(SumiTheme.foreground)
                }

                Spacer()

                StatusBadge(.neutral("Local Engine Ready"))
            }
            .padding(.bottom, 2)

            // Section: Quick Resume
            if let title = lastWatchedTitle, let ep = lastWatchedEpisode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONTINUE WATCHING")
                        .sumiTabularMono(size: 10, weight: .semibold)
                        .foregroundColor(SumiTheme.muted.opacity(0.8))

                    Button(action: {
                        onResumeLastWatched()
                        onOpenMainApp()
                    }) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                    .fill(SumiTheme.background)
                                    .frame(width: 50, height: 35)

                                Image(systemName: "play.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(SumiTheme.indigo)
                            }
                            .frame(width: 50, height: 35)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(SumiTheme.foreground)
                                    .lineLimit(1)
                                Text("Episode \(ep)")
                                    .sumiTabularMono(size: 10.5)
                                    .foregroundColor(SumiTheme.muted)
                            }

                            Spacer()

                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(SumiTheme.indigo)
                        }
                        .padding(8)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Section: Airing Today
            if !airingItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AIRING TODAY")
                            .sumiTabularMono(size: 10, weight: .semibold)
                            .foregroundColor(SumiTheme.muted.opacity(0.8))
                        Spacer()
                        Text("\(airingItems.count) SHOWS")
                            .sumiTabularMono(size: 10)
                            .foregroundColor(SumiTheme.muted)
                    }

                    VStack(spacing: 6) {
                        ForEach(airingItems) { item in
                            HStack {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(SumiTheme.foreground)
                                    .lineLimit(1)

                                Spacer()

                                Text(item.countdownText)
                                    .sumiTabularMono(size: 10.5, weight: .semibold)
                                    .foregroundColor(SumiTheme.indigo)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(SumiTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                        }
                    }
                }
            }

            Divider()
                .background(SumiTheme.border)

            // Bottom Actions
            HStack {
                Button(action: onOpenMainApp) {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                        Text("Open AniCat")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 320)
        .background(SumiTheme.background)
    }
}
