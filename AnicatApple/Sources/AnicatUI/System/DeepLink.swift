import Foundation

/// One `anicat://` address, parsed and back.
///
/// A pure value type on purpose: every system surface that can hand the app a
/// destination — the URL scheme, a notification tap — is
/// funnelled through this one representation, so `AppModel.handleDeepLink` is
/// the only place that knows how to reach a screen and the entry points
/// cannot drift apart.
public enum DeepLink: Equatable, Sendable {
    /// `anicat://title/<id>` (`?manga=1` for a manga entry, `?catalog=film`
    /// or `?catalog=series` for TMDB).
    case title(id: Int64, isManga: Bool, catalog: MediaCard.CardCatalog = .anilist)
    /// `anicat://play/<id>/<episode>` (same `?catalog=` as above).
    case play(id: Int64, episode: Int, catalog: MediaCard.CardCatalog = .anilist)
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
            self = .title(
                id: id,
                isManga: manga == "1" || manga == "true",
                catalog: Self.catalog(from: queryItems)
            )
        case "play":
            guard path.count >= 2, let id = Int64(path[0]), let episode = Int(path[1]), episode > 0 else {
                return nil
            }
            self = .play(id: id, episode: episode, catalog: Self.catalog(from: queryItems))
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
        case .title(let id, let isManga, let catalog):
            components.host = "title"
            components.path = "/\(id)"
            var items: [URLQueryItem] = []
            if isManga { items.append(URLQueryItem(name: "manga", value: "1")) }
            if let name = Self.catalogName(catalog) { items.append(URLQueryItem(name: "catalog", value: name)) }
            if !items.isEmpty { components.queryItems = items }
        case .play(let id, let episode, let catalog):
            components.host = "play"
            components.path = "/\(id)/\(episode)"
            if let name = Self.catalogName(catalog) {
                components.queryItems = [URLQueryItem(name: "catalog", value: name)]
            }
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

    /// Which catalog an id belongs to. Absent means AniList, so every link
    /// written before cinema mode existed still parses — and a link that
    /// omits it cannot silently address a film, which is what the
    /// "download finished" notification for a film used to do: it carried a
    /// TMDB id into `playFromShelf`, whose catalog defaulted to AniList.
    ///
    /// `film`/`series` rather than the enum's own `tmdbMovie`/`tmdbTv`, for
    /// the same reason the section routes are hand-named below: this is a
    /// vocabulary someone types.
    static func catalog(from items: [URLQueryItem]) -> MediaCard.CardCatalog {
        switch items.first(where: { $0.name == "catalog" })?.value?.lowercased() {
        case "film", "movie": return .tmdbMovie
        case "series", "tv": return .tmdbTv
        default: return .anilist
        }
    }

    /// Nil for AniList: the default is spelled by leaving the key out.
    static func catalogName(_ catalog: MediaCard.CardCatalog) -> String? {
        switch catalog {
        case .anilist: return nil
        case .tmdbMovie: return "film"
        case .tmdbTv: return "series"
        }
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
