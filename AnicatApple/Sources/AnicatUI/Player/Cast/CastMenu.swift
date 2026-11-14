#if os(macOS)
import AppKit
import SwiftUI

/// The TV picker in the player's top bar. The house has more than one
/// Chromecast TV, so nothing starts until one is picked by name.
struct CastMenu: View {
    @Bindable var cast: CastSession

    var body: some View {
        // A popover sizes itself once, when it opens: the rows that appear
        // once casting starts were cut off below the fold.
        ScrollView {
        VStack(alignment: .leading, spacing: 2) {
            Text("Play on TV")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            if cast.discovery.devices.isEmpty {
                Text("Looking for TVs on this network")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            ForEach(cast.discovery.devices) { device in
                let isCurrent = cast.device?.id == device.id
                Button(action: { if !isCurrent { cast.start(device) } }) {
                    HStack(spacing: 10) {
                        Image(anicat: "tv")
                            .font(.system(size: 12))
                            .foregroundColor(isCurrent ? SumiTheme.indigo : SumiTheme.muted)
                        Text(device.name)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                        Spacer()
                        if isCurrent {
                            Text(Self.label(cast.phase))
                                .sumiTabularMono(size: 11)
                                .foregroundColor(SumiTheme.muted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isCurrent ? SumiTheme.indigo.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.sumiPressable)
            }

            if case .failed(let message) = cast.phase {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            Rectangle().fill(SumiTheme.border).frame(height: 1).padding(.vertical, 4)
            HStack {
                Text("Sound")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.foreground)
                Spacer()
                SumiSlashToggle([(false, "Mac"), (true, "TV")], selection: cast.soundOnTV) { cast.soundOnTV = $0 }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            if cast.isActive {
                if !cast.soundOnTV {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Audio delay")
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.foreground)
                        Spacer()
                        Text("\(Int((cast.audioDelay * 1000).rounded())) ms")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)
                    }
                    Slider(value: $cast.audioDelay, in: -0.5...1.0, step: 0.02)
                        .tint(SumiTheme.indigo)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                }

                Button(action: { cast.stop() }) {
                    Text("Stop casting")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
        }
        .padding(8)
        }
        .frame(width: 280, height: 240)
        .onAppear { cast.discovery.start() }
        .onDisappear { cast.discovery.stop() }
    }

    static func label(_ phase: CastSession.Phase) -> String {
        switch phase {
        case .idle: return ""
        case .connecting: return "Connecting"
        case .starting: return "Starting"
        case .playing: return "Playing"
        case .buffering: return "Buffering"
        case .failed: return "Failed"
        }
    }
}

/// The player while its picture is on the TV: the Mac becomes the remote.
/// Artwork and what is playing where, and the cast's own settings. No
/// play/pause of its own: the bottom bar's stays up, and two read as two
/// different things. The player's top and bottom bars stay above it and stay
/// up (no autohide while casting), so scrubbing, skipping and the episode
/// list work as they do for any episode.
struct CastRemoteView: View {
    @Bindable var cast: CastSession
    let controller: PlayerController

    var body: some View {
        VStack(spacing: 14) {
            CachedAsyncImage(url: controller.coverURL, maxPixelSize: 480) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(anicat: "tv")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(PlayerChrome.foreground.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PlayerChrome.foreground.opacity(0.06))
            }
            .frame(width: 168, height: 252)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))

            VStack(spacing: 4) {
                Text(controller.title)
                    .font(.sumiHeading(size: 20))
                    .foregroundColor(PlayerChrome.foreground)
                    .lineLimit(1)
                Text(controller.episodeTitle.isEmpty ? "Episode \(controller.episodeNumber)" : "Episode \(controller.episodeNumber) \u{00B7} \(controller.episodeTitle)")
                    .font(.system(size: 13))
                    .foregroundColor(PlayerChrome.foreground.opacity(0.7))
                    .lineLimit(1)
                Text("\(cast.device?.name ?? "TV") \u{00B7} \(cast.phase == .playing && !controller.isPlaying ? "Paused" : CastMenu.label(cast.phase))")
                    .sumiTabularMono(size: 12)
                    .foregroundColor(SumiTheme.indigo)
            }


            HStack(spacing: 18) {
                HStack(spacing: 8) {
                    Text("Sound")
                        .font(.system(size: 12.5))
                        .foregroundColor(PlayerChrome.foreground.opacity(0.7))
                    SumiSlashToggle([(false, "Mac"), (true, "TV")], selection: cast.soundOnTV,
                                    onColor: PlayerChrome.foreground, offColor: PlayerChrome.foreground.opacity(0.45)) { cast.soundOnTV = $0 }
                }
                if !cast.soundOnTV {
                    HStack(spacing: 8) {
                        Text("Delay")
                            .font(.system(size: 12.5))
                            .foregroundColor(PlayerChrome.foreground.opacity(0.7))
                        Slider(value: $cast.audioDelay, in: -0.5...1.0, step: 0.02)
                            .frame(width: 110)
                            .tint(SumiTheme.indigo)
                        Text("\(Int((cast.audioDelay * 1000).rounded())) ms")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(PlayerChrome.foreground.opacity(0.6))
                            .frame(width: 52, alignment: .leading)
                    }
                }
            }

            SumiOutlineButton("Stop casting") { cast.stop() }
        }
        .onAppear {
            // The picture is on the TV; a fullscreen Mac window is a black
            // wall around a remote. Leave fullscreen so the rest of the
            // desktop is usable while the TV plays.
            if let window = AppWindow.main ?? NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                FullScreenGuard.toggle(on: window)
            }
            controller.cancelAutohide()
        }
    }
}
#endif
