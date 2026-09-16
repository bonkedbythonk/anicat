import ActivityKit
import SwiftUI
import WidgetKit

/// A download's progress on the lock screen and in the Dynamic Island.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(WidgetTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(context.attributes.isFilm ? "FILM" : "EP \(context.attributes.episode)") \u{00B7} \(context.state.status.uppercased())")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    ProgressView(value: context.state.percent, total: 100).tint(WidgetTheme.accent)
                }
            }
            .padding(14)
            .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(WidgetTheme.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.percent))%").font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        ProgressView(value: context.state.percent, total: 100).tint(WidgetTheme.accent)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(WidgetTheme.accent)
            } compactTrailing: {
                Text("\(Int(context.state.percent))%").font(.system(size: 12, weight: .semibold, design: .monospaced))
            } minimal: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(WidgetTheme.accent)
            }
        }
    }
}

/// What the Mac is playing while the phone is its remote. Tapping the
/// activity opens the remote sheet (`anicat://remote`).
struct RemoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "macbook.and.iphone").font(.system(size: 24)).foregroundStyle(WidgetTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("EP \(context.state.episode) \u{00B7} \(context.state.isPlaying ? "PLAYING" : "PAUSED") ON \(context.attributes.macName.uppercased())")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: min(max(context.state.currentTime, 0), max(context.state.duration, 1)), total: max(context.state.duration, 1))
                        .tint(WidgetTheme.accent)
                }
            }
            .padding(14)
            .activityBackgroundTint(.clear)
            .widgetURL(URL(string: "anicat://remote"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "macbook.and.iphone").font(.system(size: 20)).foregroundStyle(WidgetTheme.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(context.state.title) \u{00B7} EP \(context.state.episode)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        ProgressView(value: min(max(context.state.currentTime, 0), max(context.state.duration, 1)), total: max(context.state.duration, 1))
                            .tint(WidgetTheme.accent)
                    }
                }
            } compactLeading: {
                Image(systemName: "macbook.and.iphone").foregroundStyle(WidgetTheme.accent)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
            } minimal: {
                Image(systemName: "macbook.and.iphone").foregroundStyle(WidgetTheme.accent)
            }
            .widgetURL(URL(string: "anicat://remote"))
        }
    }
}
