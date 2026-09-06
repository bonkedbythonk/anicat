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
    /// Non-nil only while something is actually streaming. The transport row
    /// is driven straight off the live controller rather than off copied
    /// values: the popover has to follow a position that moves once a second
    /// while it is open, and a snapshot taken when it opened would freeze.
    public let nowPlaying: PlayerController?
    public let onOpenAiringItem: (AiringTodayItem) -> Void

    public let onResumeLastWatched: () -> Void
    public let onOpenMainApp: () -> Void
    public let onOpenSettings: () -> Void
    public let onQuit: () -> Void

    public init(
        lastWatchedTitle: String? = nil,
        lastWatchedEpisode: Int? = nil,
        lastWatchedThumbnailURL: URL? = nil,
        airingItems: [AiringTodayItem] = [],
        nowPlaying: PlayerController? = nil,
        onOpenAiringItem: @escaping (AiringTodayItem) -> Void = { _ in },
        onResumeLastWatched: @escaping () -> Void = {},
        onOpenMainApp: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.lastWatchedTitle = lastWatchedTitle
        self.lastWatchedEpisode = lastWatchedEpisode
        self.lastWatchedThumbnailURL = lastWatchedThumbnailURL
        self.airingItems = airingItems
        self.nowPlaying = nowPlaying
        self.onOpenAiringItem = onOpenAiringItem
        self.onResumeLastWatched = onResumeLastWatched
        self.onOpenMainApp = onOpenMainApp
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                if let icon = BrandAssets.menuBarIcon {
                    icon
                        .renderingMode(.template)
                        .foregroundColor(SumiTheme.indigo)
                } else {
                    Image(systemName: "cat.fill")
                        .foregroundColor(SumiTheme.indigo)
                }
                Text("ANICAT")
                    .sumiTabularMono(size: 12, weight: .bold)
                    .foregroundColor(SumiTheme.foreground)

                Spacer()
            }
            .padding(.bottom, 2)

            // Section: Quick Resume
            if let title = lastWatchedTitle, let ep = lastWatchedEpisode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(nowPlaying == nil ? "CONTINUE WATCHING" : "NOW PLAYING")
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
                                    .frame(width: 44, height: 32)

                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(SumiTheme.indigo)
                            }
                            .frame(width: 44, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(SumiTheme.foreground)
                                    .lineLimit(1)
                                Text("Episode \(ep)")
                                    .sumiTabularMono(size: 10)
                                    .foregroundColor(SumiTheme.muted)
                            }

                            Spacer()

                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 15))
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
                    .buttonStyle(.sumiPressable)

                    if let controller = nowPlaying {
                        TransportRow(controller: controller)
                    }
                }
            }

            if !airingItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AIRING TODAY")
                        .sumiTabularMono(size: 10, weight: .semibold)
                        .foregroundColor(SumiTheme.muted.opacity(0.8))

                    // Capped, and scrolled rather than grown: a heavy season
                    // puts a dozen shows on one day, and a menu bar popover
                    // taller than the screen is clipped by AppKit with no
                    // scroll of its own.
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(airingItems) { item in
                                Button {
                                    onOpenAiringItem(item)
                                    onOpenMainApp()
                                } label: {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title)
                                                .font(.system(size: 12))
                                                .foregroundColor(SumiTheme.foreground)
                                                .lineLimit(1)
                                            Text("EP \(item.episodeNumber)")
                                                .sumiTabularMono(size: 9.5)
                                                .foregroundColor(SumiTheme.muted)
                                        }
                                        Spacer(minLength: 6)
                                        Text(item.countdownText)
                                            .sumiTabularMono(size: 9.5)
                                            .foregroundColor(SumiTheme.muted)
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.sumiPressable)
                            }
                        }
                    }
                    .frame(maxHeight: 132)
                }
            }

            Divider()
                .background(SumiTheme.border)

            // Bottom Actions. Three equal-width slots (rather than one
            // `Spacer()` either side of the gear icon) so the gear actually
            // lands in the row's visual center — with plain spacers, two
            // unequal-width siblings ("Open Anicat" is icon+text, "Quit" is
            // text alone) get equal leftover space either side of the middle
            // button, not equal *total* space, so the gear sat visibly
            // off-center toward whichever side had the narrower neighbor.
            HStack(spacing: 0) {
                Button(action: onOpenMainApp) {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                        Text("Open Anicat")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                }
                .buttonStyle(.sumiPressable)
                // Carried over from the discrete-Button menu-bar layout this
                // popover replaced — that version bound these on plain
                // `Button.keyboardShortcut`, and converting to a custom
                // `MenuBarView` dropped both silently along with it.
                .keyboardShortcut("o", modifiers: .command)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }
                .buttonStyle(.sumiPressable)
                .keyboardShortcut(",", modifiers: .command)
                .frame(maxWidth: .infinity, alignment: .center)

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }
                .buttonStyle(.sumiPressable)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 260)
        .background(SumiTheme.background)
    }
}

/// Scrubber, play/pause and next-episode for whatever is streaming, without
/// having to bring the window forward first.
private struct TransportRow: View {
    /// `@Bindable`, not a plain `let`: `PlayerController` is `@Observable`,
    /// and only a bindable reference makes this body re-run on the
    /// once-a-second `currentTime` write that moves the bar.
    @Bindable var controller: PlayerController

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SumiTheme.foreground.opacity(0.16))
                        .frame(height: 3)
                    Capsule()
                        .fill(SumiTheme.indigo)
                        .frame(width: geo.size.width * CGFloat(controller.progressFraction), height: 3)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // `isScrubbing` is what stops the position poll
                            // from writing over the handle mid-drag; the seek
                            // itself waits for the release, so dragging
                            // across the bar does not fire a seek per pixel
                            // into a torrent that has to fetch each one.
                            controller.isScrubbing = true
                            let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                            controller.currentTime = Double(fraction) * controller.duration
                        }
                        .onEnded { value in
                            let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                            let target = Double(fraction) * controller.duration
                            controller.isScrubbing = false
                            controller.seek(to: target)
                        }
                )
            }
            .frame(height: 14)

            HStack(spacing: 10) {
                Text(controller.formattedCurrentTime)
                    .sumiTabularMono(size: 9.5)
                    .foregroundColor(SumiTheme.muted)

                Spacer(minLength: 4)

                Button(action: { controller.togglePlayPause() }) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.foreground)
                }
                .buttonStyle(.sumiPressable)

                Button(action: { controller.nextEpisode() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 12))
                        .foregroundColor(controller.hasNextEpisode ? SumiTheme.foreground : SumiTheme.muted.opacity(0.5))
                }
                .buttonStyle(.sumiPressable)
                .disabled(!controller.hasNextEpisode)

                Spacer(minLength: 4)

                Text(controller.formattedDuration)
                    .sumiTabularMono(size: 9.5)
                    .foregroundColor(SumiTheme.muted)
            }
        }
        .padding(.top, 2)
    }
}
