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

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TrailerWebViewConfiguration.make())
        // The banner sits on the page ground with a gradient over it, and a
        // web view paints opaque white until the embed's first frame lands.
        view.underPageBackgroundColor = .clear
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }

    /// Loading `about:blank` rather than trusting deallocation: a web view
    /// that is merely released keeps its media session alive long enough to
    /// be heard under the stream the viewer just started.
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
#else
private struct TrailerWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: TrailerWebViewConfiguration.make())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }

    /// See the macOS twin: releasing the view is not enough to stop audio.
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
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
