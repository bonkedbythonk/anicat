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
struct TrailerPlayer: View {
    let site: String?
    let videoId: String

    var body: some View {
        if let url = Self.embedURL(site: site, videoId: videoId) {
            TrailerWebView(url: url)
        } else {
            Color.black
        }
    }

    /// `nil` for a site nothing here can embed, which is how the caller
    /// decides not to offer the trailer at all.
    static func embedURL(site: String?, videoId: String) -> URL? {
        guard !videoId.isEmpty,
              let escaped = videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        switch site?.lowercased() {
        case "youtube", nil:
            // `youtube-nocookie.com`, not `youtube.com`: the standard embed
            // sets its tracking cookies before anything is played.
            return URL(string: "https://www.youtube-nocookie.com/embed/\(escaped)?autoplay=1&mute=1&controls=1&playsinline=1&rel=0")
        case "dailymotion":
            return URL(string: "https://www.dailymotion.com/embed/video/\(escaped)?autoplay=1&mute=1")
        default:
            return nil
        }
    }
}

#if os(macOS)
private struct TrailerWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> TrailerLoadState { TrailerLoadState() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TrailerWebViewConfiguration.make())
        // The banner sits on the page ground with a gradient over it, and a
        // web view paints opaque white until the embed's first frame lands.
        view.underPageBackgroundColor = .clear
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
    }

    /// Loading `about:blank` rather than trusting deallocation: a web view
    /// that is merely released keeps its media session alive long enough to
    /// be heard under the stream the viewer just started.
    static func dismantleNSView(_ view: WKWebView, coordinator: TrailerLoadState) {
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
#else
private struct TrailerWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> TrailerLoadState { TrailerLoadState() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TrailerWebViewConfiguration.make())
        view.isOpaque = false
        view.backgroundColor = .clear
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        TrailerEmbedPage.load(url, into: view, state: context.coordinator)
    }

    /// See the macOS twin: releasing the view is not enough to stop audio.
    static func dismantleUIView(_ view: WKWebView, coordinator: TrailerLoadState) {
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
/// same trailer does not reload it mid-play.
final class TrailerLoadState {
    var loaded: URL?
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
