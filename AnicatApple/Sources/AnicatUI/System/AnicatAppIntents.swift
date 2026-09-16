import Foundation
import AppIntents

/// One title from the watching list, as Shortcuts and Siri see it.
///
/// The identifier is `Int`, not the `Int64` the catalog uses everywhere else:
/// `EntityIdentifierConvertible` is implemented for `Int`, `String` and
/// `UUID` and nothing else, so an `Int64` id makes the entity fail to
/// conform with no useful diagnostic.
public struct WatchingTitleEntity: AppEntity {
    public let id: Int
    public let title: String
    public let nextEpisode: Int

    public var catalogId: Int64 { Int64(id) }

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Anime")
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "Episode \(nextEpisode)")
    }

    public static let defaultQuery = WatchingTitleQuery()
}

/// Answers Shortcuts' "which titles are there" from the live Up Next list.
///
/// `EntityStringQuery` and not just `EntityQuery`: a spoken phrase hands the
/// runtime a string, never an identifier, so without `entities(matching:)`
/// the parameter can only be filled from the picker and every voice
/// invocation falls back to asking again.
public struct WatchingTitleQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [Int]) async throws -> [WatchingTitleEntity] {
        let wanted = Set(identifiers)
        return await allEntities().filter { wanted.contains($0.id) }
    }

    public func entities(matching string: String) async throws -> [WatchingTitleEntity] {
        let needle = string.lowercased()
        return await allEntities().filter { $0.title.lowercased().contains(needle) }
    }

    public func suggestedEntities() async throws -> [WatchingTitleEntity] {
        await allEntities()
    }

    private func allEntities() async -> [WatchingTitleEntity] {
        await MainActor.run {
            (AppModel.shared?.upNextItems ?? [])
                .filter { $0.unit != "CH" }
                .map {
                    WatchingTitleEntity(
                        id: Int($0.id),
                        title: $0.title,
                        nextEpisode: $0.nextEpisodeOrChapter
                    )
                }
        }
    }
}

/// "Continue watching in Anicat" — the same thing the menu bar's Resume card
/// does, reached from Shortcuts, Siri and Spotlight's action row.
public struct ContinueWatchingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Continue Watching"
    public static let description = IntentDescription("Plays the next episode of whatever you watched last.")
    /// Every intent here ends in the app: the resolve, the player and the
    /// detail page are all UI. An intent that ran in the background would
    /// start a torrent resolve into a window nobody is looking at.
    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared, let first = model.upNextItems.first else {
            throw AppIntentError.nothingToResume
        }
        model.handleDeepLink(
            first.unit == "CH"
                ? .title(id: first.id, isManga: true)
                : .play(id: first.id, episode: first.nextEpisodeOrChapter)
        )
        return .result()
    }
}

/// "Play the next episode of <title> in Anicat".
public struct PlayNextEpisodeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play Next Episode"
    public static let description = IntentDescription("Plays the next unwatched episode of a title you are watching.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Title")
    public var target: WatchingTitleEntity

    public init() {}

    public init(target: WatchingTitleEntity) {
        self.target = target
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Play the next episode of \(\.$target)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else { throw AppIntentError.appNotReady }
        // The entity was built from a list that may be minutes old, so the
        // episode number is re-read from the live list where it is still
        // there. Falling back to the entity's own number keeps a stale pick
        // playing something rather than failing.
        let episode = model.upNextItems.first { $0.id == target.catalogId }?.nextEpisodeOrChapter
            ?? target.nextEpisode
        model.handleDeepLink(.play(id: target.catalogId, episode: episode))
        return .result()
    }
}

/// "Open <title> in Anicat" — the detail page, not playback.
public struct OpenTitleIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Title"
    public static let description = IntentDescription("Opens a title's page in Anicat.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Title")
    public var target: WatchingTitleEntity

    public init() {}

    public init(target: WatchingTitleEntity) {
        self.target = target
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else { throw AppIntentError.appNotReady }
        model.handleDeepLink(.title(id: target.catalogId, isManga: false))
        return .result()
    }
}

/// "What am I watching in Anicat" — answers out loud and leaves the app
/// alone, which is the one intent here that has a reason not to open it.
public struct WhatAmIWatchingIntent: AppIntent {
    public static let title: LocalizedStringResource = "What Am I Watching"
    public static let description = IntentDescription("Says which episode of which title is playing, or was last watched.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else { throw AppIntentError.appNotReady }

        // Something on screen right now beats the list: `upNextItems` is
        // sorted by AniList's `updatedAt`, which does not move until progress
        // is recorded, so mid-episode it still names the previous show.
        if model.activeStreamURL != nil {
            let title = model.currentPlaybackTitle ?? model.playerController.title
            let episode = model.currentPlaybackEpisode.map(Int.init) ?? model.playerController.episodeNumber
            if !title.isEmpty {
                return .result(dialog: IntentDialog("You are watching \(title), episode \(episode)."))
            }
        }

        guard let first = model.upNextItems.first else {
            return .result(dialog: IntentDialog("You have nothing in progress right now."))
        }
        let unit = first.unit == "CH" ? "chapter" : "episode"
        return .result(
            dialog: IntentDialog("You were last on \(first.title). Next up is \(unit) \(first.nextEpisodeOrChapter).")
        )
    }
}

/// Failures the runtime shows the user verbatim, so each string is written to
/// be read out rather than logged.
public enum AppIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case nothingToResume

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "Anicat is still starting up."
        case .nothingToResume: return "There is nothing in your Up Next queue."
        }
    }
}

/// The phrases Siri and Spotlight accept. Every one has to contain
/// `\(.applicationName)` — the builder rejects a phrase without it, because
/// there is nothing in "continue watching" that says which app should answer.
public struct AnicatShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueWatchingIntent(),
            phrases: [
                "Continue watching in \(.applicationName)",
                "Resume \(.applicationName)",
                "Play my next episode in \(.applicationName)"
            ],
            shortTitle: "Continue Watching",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: WhatAmIWatchingIntent(),
            phrases: [
                "What am I watching in \(.applicationName)",
                "What is next in \(.applicationName)"
            ],
            shortTitle: "What Am I Watching",
            systemImageName: "questionmark.circle"
        )
        AppShortcut(
            intent: PlayNextEpisodeIntent(),
            phrases: [
                "Play the next episode in \(.applicationName)"
            ],
            shortTitle: "Play Next Episode",
            systemImageName: "forward.end.fill"
        )
        AppShortcut(
            intent: OpenTitleIntent(),
            phrases: [
                "Open a title in \(.applicationName)"
            ],
            shortTitle: "Open Title",
            systemImageName: "rectangle.stack"
        )
    }
}
