import SwiftUI

public struct PlayerView: View {
    @Bindable public var controller: PlayerController
    public let streamURL: URL?
    public let onClose: () -> Void

    public init(controller: PlayerController, streamURL: URL? = nil, onClose: @escaping () -> Void) {
        self.controller = controller
        self.streamURL = streamURL
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            // Background Canvas (Black)
            Color.black
                .ignoresSafeArea()

            #if os(macOS)
            MpvMetalSurface(controller: controller, streamURL: streamURL)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.togglePlayPause()
                }
            #else
            VStack {
                Spacer()
                Image(systemName: "film")
                    .font(.system(size: 64))
                    .foregroundColor(SumiTheme.muted.opacity(0.4))
                Text(controller.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground.opacity(0.7))
                    .padding(.top, 8)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                controller.togglePlayPause()
            }
            #endif

            // Paused Overlay Icon
            if !controller.isPlaying && controller.areControlsVisible {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundColor(SumiTheme.indigo.opacity(0.9))
                    .transition(.scale.combined(with: .opacity))
            }

            // Controls Overlay
            if controller.areControlsVisible {
                VStack {
                    // Top Bar
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))

                    Spacer()

                    // Bottom Bar
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .padding(SumiTheme.spaceLg)
            }

            // AniSkip Floating Action Pill (Bottom Right)
            if controller.isIntroActive {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                controller.skipIntro()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 12))
                                Text("Skip Opening")
                                    .sumiTabularMono(size: 12, weight: .bold)
                            }
                            .foregroundColor(SumiTheme.background)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(SumiTheme.indigo)
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 24)
                        .padding(.bottom, controller.areControlsVisible ? 80 : 24)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: controller.isIntroActive)
            }
        }
        #if os(macOS)
        .onContinuousHover { _ in
            controller.showControlsBriefly()
        }
        #endif
        .animation(.easeInOut(duration: 0.25), value: controller.areControlsVisible)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                Text("Episode \(controller.episodeNumber)")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
            }

            Spacer()

            // Anime4K Preset Pill
            Button(action: { controller.cycleAnime4K() }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                    Text("Anime4K: \(controller.activeAnime4KPreset.displayName)")
                        .sumiTabularMono(size: 11, weight: .semibold)
                }
                .foregroundColor(controller.activeAnime4KPreset != .off ? SumiTheme.indigo : SumiTheme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Bottom Bar
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Scrubber Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)

                    // Fill
                    Capsule()
                        .fill(SumiTheme.indigo)
                        .frame(width: geo.size.width * CGFloat(controller.progressFraction), height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                            controller.seek(to: Double(fraction) * controller.duration)
                        }
                )
            }
            .frame(height: 12)

            // Transport Controls Row
            HStack(spacing: 20) {
                // Play / Pause
                Button(action: { controller.togglePlayPause() }) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(SumiTheme.foreground)
                }
                .buttonStyle(.plain)

                // Seek -10s
                Button(action: { controller.seekRelative(by: -10) }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 16))
                        .foregroundColor(SumiTheme.foreground.opacity(0.8))
                }
                .buttonStyle(.plain)

                // Seek +10s
                Button(action: { controller.seekRelative(by: 10) }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 16))
                        .foregroundColor(SumiTheme.foreground.opacity(0.8))
                }
                .buttonStyle(.plain)

                // Time Display
                HStack(spacing: 4) {
                    Text(controller.formattedCurrentTime)
                        .foregroundColor(SumiTheme.foreground)
                    Text("/")
                        .foregroundColor(SumiTheme.muted)
                    Text(controller.formattedDuration)
                        .foregroundColor(SumiTheme.muted)
                }
                .sumiTabularMono(size: 12)

                Spacer()

                // Picture-in-Picture
                Button(action: {}) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 15))
                        .foregroundColor(SumiTheme.foreground.opacity(0.8))
                }
                .buttonStyle(.plain)

                // Fullscreen
                Button(action: {}) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14))
                        .foregroundColor(SumiTheme.foreground.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }
}
