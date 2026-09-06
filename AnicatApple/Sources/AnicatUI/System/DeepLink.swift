import Foundation

/// One `anicat://` address, parsed and back.
///
/// A pure value type on purpose: every system surface that can hand the app a
/// destination — the URL scheme, a Spotlight result, a notification tap — is
/// funnelled through this one representation, so `AppModel.handleDeepLink` is
/// the only place that knows how to reach a screen and the entry points
/// cannot drift apart.
public enum DeepLink: Equatable, Sendable {
    /// `anicat://title/<anilistId>` (`?manga=1` for a manga entry).
    case title(id: Int64, isManga: Bool)
    /// `anicat://play/<anilistId>/<episode>`.
    case play(id: Int64, episode: Int)
    /// `anicat://search?q=<text>`.
    case search(query: String)
    /// `anicat://section/<home|schedule|library|manga|novels|search|history|downloads|settings>`.
    case section(SidebarView.NavSection)

    public static let scheme = "anicat"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        // `URL.pathComponents` for `anicat://title/123` is ["/", "123"], not
        // ["title", "123"]: the first segment is the authority and lands in
        // `host`, and the separator is an element of its own.
        let path = url.pathComponents.filter { $0 != "/" }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch host {
        case "title":
            guard let id = path.first.flatMap(Int64.init) else { return nil }
            let manga = queryItems.first { $0.name == "manga" }?.value?.lowercased()
            self = .title(id: id, isManga: manga == "1" || manga == "true")
        case "play":
            guard path.count >= 2, let id = Int64(path[0]), let episode = Int(path[1]), episode > 0 else {
                return nil
            }
            self = .play(id: id, episode: episode)
        case "search":
            self = .search(query: queryItems.first { $0.name == "q" }?.value ?? "")
        case "section":
            guard let name = path.first, let section = Self.section(named: name) else { return nil }
            self = .section(section)
        default:
            return nil
        }
    }

    /// The address this link parses from. A notification payload can only
    /// carry plain values, so the destination travels through it as this
    /// string and comes back through `init(url:)`.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .title(let id, let isManga):
            components.host = "title"
            components.path = "/\(id)"
            if isManga { components.queryItems = [URLQueryItem(name: "manga", value: "1")] }
        case .play(let id, let episode):
            components.host = "play"
            components.path = "/\(id)/\(episode)"
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .section(let section):
            components.host = "section"
            components.path = "/\(Self.routeName(for: section))"
        }
        // Every case above sets both a scheme and a host, so nothing here can
        // fail to compose; the fallback exists only because
        // `URLComponents.url` is optional.
        return components.url ?? URL(string: "\(Self.scheme)://section/home")!
    }

    /// The route names are their own vocabulary rather than
    /// `NavSection.rawValue`: two of those raw values are the web build's old
    /// route names (`lists` for the library, `profile` for history), which
    /// nobody writing a link would guess, and renaming them would move the
    /// keys the sidebar has already persisted.
    static func section(named name: String) -> SidebarView.NavSection? {
        switch name.lowercased() {
        case "home": return .upNext
        case "schedule": return .schedule
        case "library": return .library
        case "manga": return .manga
        case "novels": return .novels
        case "search": return .search
        case "history": return .history
        case "stats": return .stats
        case "downloads": return .downloads
        case "settings": return .settings
        default: return nil
        }
    }

    static func routeName(for section: SidebarView.NavSection) -> String {
        switch section {
        case .upNext: return "home"
        case .schedule: return "schedule"
        case .library: return "library"
        case .manga: return "manga"
        case .novels: return "novels"
        case .search: return "search"
        case .history: return "history"
        case .stats: return "stats"
        case .downloads: return "downloads"
        case .settings: return "settings"
        }
    }
}
