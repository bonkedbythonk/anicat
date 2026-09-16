import SwiftUI
import WebKit

/// The AniList trailer, embedded in place of the detail page's banner.
///
/// A web view rather than an `AVPlayer`: AniList stores a YouTube or
/// Dailymotion video id and nothing else, and neither site serves a media
/// URL an `AVPlayer` could open. The embed is the only playable form of what
/// the catalog actually gives us.
///
/// It starts muted because the page it covers is one click away from
/// starting a stream, and an autoplaying trailer with sound is what makes
/// that click feel like a bug. Unmuting is the embedded player's own
/// control, not ours.
///
/// When YouTube refuses to play inside the embed, the same frame shows the
/// trailer's thumbnail and a button that opens it in the browser instead.
/// See `TrailerEmbedStatus` for why refusal is expected rather than rare.
struct TrailerPlayer: View {
    let site: String?
    let videoId: String
    var thumbnail: URL? = nil

    @State private var status: TrailerEmbedStatus = .loading

    var body: some View {
        if let url = Self.embedURL(site: site, videoId: videoId) {
            ZStack {
                TrailerWebView(url: url) { status = $0 }
                    // Kept mounted, not swapped out: the refusal card is
                    // YouTube's own decision for this network, and the same
                    // web view is what would play if the decision changed.
                    .opacity(status.isBlocked ? 0 : 1)
                if case .blocked(let reason) = status {
                    TrailerBlockedView(
                        reason: reason,
                        thumbnail: thumbnail ?? Self.thumbnailURL(site: site, videoId: videoId),
                        siteName: Self.siteName(site),
                        watchURL: Self.watchURL(site: site, videoId: videoId)
                    )
                    .transition(.opacity)
                }
            }
            .animation(.sumi(.pop), value: status)
            .onChange(of: videoId) { _, _ in status = .loading }
        } else {
            Color.black
        }
    }

    /// `nil` for a site nothing here can embed, which is how the caller
    /// decides not to offer the trailer at all.
    static func embedURL(site: String?, videoId: String) -> URL? {
        guard let escaped = Self.escaped(videoId) else { return nil }
        switch site?.lowercased() {
        case "youtube", nil:
            // `youtube-nocookie.com`, not `youtube.com`: the standard embed
            // sets its tracking cookies before anything is played. Neither
            // host, nor a Safari user agent, `origin=`/`enablejsapi=1`, a
            // warmed cookie store or an ephemeral one changed the "Sign in
            // to confirm you're not a bot" answer (measured 2026-09-07, 13
            // variants, all refused; the plain watch page in a clean browser
            // on the same network was refused too). The decision is made per
            // network, so the fallback below is the fix, not a header.
            return URL(string: "https://www.youtube-nocookie.com/embed/\(escaped)?autoplay=1&mute=1&controls=1&playsinline=1&rel=0&modestbranding=1&iv_load_policy=3")
        case "dailymotion":
            return URL(string: "https://www.dailymotion.com/embed/video/\(escaped)?autoplay=1&mute=1")
        default:
            return nil
        }
    }

    /// The trailer as a page the default browser can open, where the
    /// viewer's own YouTube session applies.
    static func watchURL(site: String?, videoId: String) -> URL? {
        guard let escaped = Self.escaped(videoId) else { return nil }
        switch site?.lowercased() {
        case "youtube", nil: return URL(string: "https://www.youtube.com/watch?v=\(escaped)")
        case "dailymotion": return URL(string: "https://www.dailymotion.com/video/\(escaped)")
        default: return nil
        }
    }

    /// AniList's `trailer.thumbnail` is exactly this URL for YouTube; built
    /// here too so a cached detail snapshot without the field still gets a
    /// picture behind the refusal card.
    static func thumbnailURL(site: String?, videoId: String) -> URL? {
        guard let escaped = Self.escaped(videoId) else { return nil }
        switch site?.lowercased() {
        case "youtube", nil: return URL(string: "https://i.ytimg.com/vi/\(escaped)/hqdefault.jpg")
        default: return nil
        }
    }

    static func siteName(_ site: String?) -> String {
        switch site?.lowercased() {
        case "dailymotion": return "Dailymotion"
        default: return "YouTube"
        }
    }

    private static func escaped(_ videoId: String) -> String? {
        guard !videoId.isEmpty else { return nil }
        return videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }
}

/// What the embed turned into, as far as the host can tell from outside.
///
/// YouTube's iframe API reports nothing useful here: under the sign-in wall
/// it still sends `onReady` and `infoDelivery` and never an `onError`, so
/// the status is read off the player frame's DOM instead
/// (`TrailerLoadState.poll`).
enum TrailerEmbedStatus: Equatable {
    case loading
    /// The player frame drew a video that has started, or at least a player
    /// in a state that will.
    case playing
    /// The player frame drew an error card instead. `reason` is its first
    /// line, e.g. "Sign in to confirm you're not a bot".
    case blocked(String)

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// The trailer thumbnail with the reason the embed refused and a way out.
private struct TrailerBlockedView: View {
    let reason: String
    let thumbnail: URL?
    let siteName: String
    let watchURL: URL?

    var body: some View {
        ZStack {
            Color.black
            CachedAsyncImage(url: thumbnail, maxPixelSize: 1280) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.black
            }
            .opacity(0.45)
            .clipped()
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("\(siteName) will not play this here")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                    Text(reason)
                        .sumiTabularMono(size: 11)
                        .foregroundColor(SumiTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let watchURL {
                    Button {
                        Platform.openExternal(watchURL)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Watch on \(siteName)")
                                .sumiTabularMono(size: 11.5, weight: .medium)
                        }
                        .foregroundColor(SumiTheme.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(SumiTheme.indigo)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.sumiPressable)
                }
            }
            .padding(24)
            .background(SumiTheme.background.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
            .overlay(RoundedRectangle(cornerRadius: SumiTheme.radiusLg).stroke(SumiTheme.border, lineWidth: 1))
        }
    }
}

#if os(macOS)
private struct TrailerWebView: NSViewRepresentable {
    let url: URL
    let onStatus: (TrailerEmbedStatus) -> Void

    func makeCoordinator() -> TrailerLoadState { TrailerLoadState() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TrailerWebViewConfiguration.make())
        // The banner sits on the page ground with a gradient over it, and a
        // web view paints opaque white until the embed's first frame lands.
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.onStatus = onStatus
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
    }

    /// Stopped explicitly rather than by deallocation, and `pauseAllMedia`
    /// first.
    ///
    /// Blanking the page was already here and was not enough on its own:
    /// `loadHTMLString` is asynchronous, SwiftUI releases the web view as
    /// soon as this returns, and the navigation that would have torn the
    /// iframe down never commits -- so the trailer went on playing, audible
    /// under whatever the viewer did next. `pauseAllMediaPlayback` reaches
    /// the content process directly and does not depend on a navigation
    /// landing, which is the only part of this that stops a cross-origin
    /// YouTube iframe. The blank load stays as the belt to its braces.
    static func dismantleNSView(_ view: WKWebView, coordinator: TrailerLoadState) {
        coordinator.stopPolling()
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.closeAllMediaPresentations(completionHandler: {})
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
#else
private struct TrailerWebView: UIViewRepresentable {
    let url: URL
    let onStatus: (TrailerEmbedStatus) -> Void

    func makeCoordinator() -> TrailerLoadState { TrailerLoadState() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TrailerWebViewConfiguration.make())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.onStatus = onStatus
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
    }

    /// See the macOS twin: releasing the view is not enough to stop audio,
    /// and neither is a blank load that never commits.
    static func dismantleUIView(_ view: WKWebView, coordinator: TrailerLoadState) {
        coordinator.stopPolling()
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.closeAllMediaPresentations(completionHandler: {})
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
#endif

private enum TrailerWebViewConfiguration {
    // WKWebViewConfiguration is main-actor isolated on CI's toolchain (the
    // local one let a nonisolated static build it); the representables
    // that call this run on the main actor anyway.
    @MainActor
    static func make() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Without this the embed shows a play button and waits: `autoplay=1`
        // in the URL is a request the embed makes, and WebKit refuses it
        // unless the host says a gesture is not required.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        // Otherwise iOS hands the video to the full-screen system player the
        // moment it starts, which is not "in place of the banner".
        configuration.allowsInlineMediaPlayback = true
        #endif
        return configuration
    }
}

/// Which embed a web view currently shows, so a SwiftUI update with the
/// same trailer does not reload it mid-play; and the watcher that reads the
/// player frame to learn whether the embed played or refused.
@MainActor
final class TrailerLoadState: NSObject, WKNavigationDelegate {
    var loaded: URL?
    var onStatus: ((TrailerEmbedStatus) -> Void)?

    /// The frame YouTube's player lives in. Cross-origin from our page, so
    /// nothing in the page's own script can look inside it; the host can.
    private var playerFrame: WKFrameInfo?
    private var polling: Task<Void, Never>?

    /// How long to keep asking before giving up on a frame that shows
    /// neither a player nor an error. A slow network must not be reported
    /// as a refusal, so giving up leaves the web view as it is.
    private static let pollBudget: Duration = .seconds(20)
    private static let pollInterval: Duration = .milliseconds(500)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the frame that loads the embed host is the player. The player
        // itself spawns `about:blank` subframes, and taking the last subframe
        // seen pointed the poll at one of those: "target frame could not be
        // found" on every read, and no status ever.
        if let frame = navigationAction.targetFrame, !frame.isMainFrame,
           let host = navigationAction.request.url?.host, Self.isEmbedHost(host) {
            playerFrame = frame
            startPolling(in: webView)
        }
        decisionHandler(.allow)
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private static func isEmbedHost(_ host: String) -> Bool {
        host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") || host.hasSuffix("dailymotion.com")
    }

    private func startPolling(in webView: WKWebView) {
        stopPolling()
        polling = Task { [weak self, weak webView] in
            let deadline = ContinuousClock.now + Self.pollBudget
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self, let webView else { return }
                switch await self.readPlayerFrame(in: webView) {
                case .playing:
                    self.onStatus?(.playing)
                    return
                case .blocked(let reason):
                    self.onStatus?(.blocked(reason))
                    return
                case .loading:
                    continue
                }
            }
        }
    }

    /// Reads the player frame's DOM. YouTube renders every refusal (the bot
    /// wall, "Video unavailable", "configuration error") as a `.ytp-error`
    /// card, and a video that has started as a `video` element with time on
    /// it or a `#movie_player` in a playback mode.
    private func readPlayerFrame(in webView: WKWebView) async -> TrailerEmbedStatus {
        guard let playerFrame else { return .loading }
        let script = """
        (() => {
          const err = document.querySelector('.ytp-error');
          if (err) return 'blocked:' + (err.innerText || '').trim().split('\\n')[0].slice(0, 120);
          const v = document.querySelector('video');
          if (v && (v.currentTime > 0 || v.readyState >= 2)) return 'playing';
          const mp = document.getElementById('movie_player');
          if (mp && /(playing|buffering|paused|ended)-mode/.test(mp.className)) return 'playing';
          return 'loading';
        })()
        """
        let result: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: playerFrame, in: .page) { outcome in
                // A frame that navigated away since it was captured answers
                // with WKErrorDomain 12; the next `decidePolicyFor` replaces
                // it, so an error is just "not yet".
                continuation.resume(returning: (try? outcome.get()) as? String)
            }
        }
        guard let result else { return .loading }
        if result == "playing" { return .playing }
        if result.hasPrefix("blocked:") {
            let reason = String(result.dropFirst("blocked:".count))
            return .blocked(reason.isEmpty ? "The embedded player refused to play" : reason)
        }
        return .loading
    }
}

/// The embed wrapped in a page of our own instead of loaded as the top
/// document. Loaded directly, YouTube's player answered "Video player
/// configuration error": the embed requires a referring page, and a
/// top-level load has none. A one-iframe page with a base URL gives it one.
enum TrailerEmbedPage {
    static let baseURL = URL(string: "https://anicat.app/")

    @MainActor
    static func load(_ url: URL, into view: WKWebView, state: TrailerLoadState) {
        guard state.loaded != url else { return }
        state.loaded = url
        let src = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body><iframe src="\(src)" allow="autoplay; encrypted-media; fullscreen; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        view.loadHTMLString(html, baseURL: baseURL)
    }
}
