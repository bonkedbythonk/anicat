// MangaDex@Home load reports.
//
// Chapter pages come from MangaDex@Home, a volunteer CDN, and MangaDex's
// API rules require a client to POST one report to api.mangadex.network for
// every image it fetches from a node, failures included. The network scores
// nodes on those reports and routes readers away from a node that is slow
// or failing; a client that never reports is removed from at-home routing,
// after which /at-home/server keeps answering and the page images it names
// stop loading, with nothing in the reader to say why.

import Foundation

enum MangaDexHomeReporter {
    static let endpoint = URL(string: "https://api.mangadex.network/report")!

    /// One completed page fetch, in the shape the endpoint takes. Property
    /// names are the JSON keys.
    struct Report: Encodable, Equatable, Sendable {
        let url: String
        let success: Bool
        let bytes: Int
        /// Milliseconds.
        let duration: Int
        /// Whether the node itself served the image from its cache, which is
        /// its `X-Cache` header and nothing to do with this app's `URLCache`.
        let cached: Bool
    }

    /// Whether `url` is a page served by a MangaDex@Home node, the only
    /// fetch the endpoint wants to hear about. `uploads.mangadex.org` is
    /// MangaDex's own origin (covers, and pages on the days it serves them
    /// itself) and a report for it is rejected; MangaKatana pages have no
    /// `/data/` segment; a downloaded chapter is read back as `file://`.
    /// A node's base URL may carry a token path segment ahead of `/data/`,
    /// which is why this is a substring test and not a prefix.
    static func isAtHomeURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "mangadex.org" || host.hasSuffix(".mangadex.org") { return false }
        let path = url.path
        return path.contains("/data/") || path.contains("/data-saver/")
    }

    /// `statusCode` is nil when the request never produced a response, which
    /// the network wants to hear about as a failure with zero bytes.
    static func makeReport(
        url: URL,
        statusCode: Int?,
        xCache: String?,
        bytes: Int,
        durationNanoseconds: UInt64
    ) -> Report {
        Report(
            url: url.absoluteString,
            success: statusCode.map { (200..<300).contains($0) } ?? false,
            bytes: bytes,
            duration: Int(durationNanoseconds / 1_000_000),
            cached: xCache?.uppercased().hasPrefix("HIT") ?? false
        )
    }

    /// Ephemeral and its own: the shared session's cache must never hold a
    /// report, and `waitsForConnectivity` would keep a report queued for the
    /// whole offline stretch to describe a fetch nobody remembers.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Fire and forget. The response is discarded and nothing here throws:
    /// a report that fails is the network's loss, never the reader's.
    static func submit(_ report: Report) {
        guard let body = try? JSONEncoder().encode(report) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// The call site's one line: builds the report from what the fetch left
    /// behind and sends it.
    static func report(url: URL, response: URLResponse?, bytes: Int, durationNanoseconds: UInt64) {
        let http = response as? HTTPURLResponse
        submit(makeReport(
            url: url,
            statusCode: http?.statusCode,
            xCache: http?.value(forHTTPHeaderField: "X-Cache"),
            bytes: bytes,
            durationNanoseconds: durationNanoseconds
        ))
    }
}
