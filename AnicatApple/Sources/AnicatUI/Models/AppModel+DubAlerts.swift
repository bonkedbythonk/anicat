// AppModel, dub alerts: telling someone who watches dubbed that the English
// dub of their next episode has turned up. AniList's airing time is the
// Japanese broadcast; a dub follows days to months later on no schedule
// anyone publishes, so the only way to know is to look where the player
// would look -- the indexers -- for a release labelled as a dub.

import Foundation
import AnicatCoreKit

extension AppModel {
    /// What one search said about one episode's dub.
    enum DubCheckResult: Equatable {
        case dub
        case noDub
        /// The search failed or found no release of the episode at all. Not
        /// "no dub": during a Nyaa outage every episode looks undubbed, and
        /// recording that would announce weeks-old dubs as new the moment
        /// the indexer came back.
        case unknown
    }

    /// Per `<catalogId>:<episode>`, what the last good search found:
    /// `waiting` (released, no dub yet) or `out`.
    static let dubWatchKey = "anicat_dub_watch"
    /// A title-episode is searched at most this often. A dub lands once and
    /// stays; a few hours late is still news, and eight titles an hour at
    /// full breadth is already more requests than one play makes.
    static let dubRecheckInterval: TimeInterval = 3 * 3600
    /// Dubs keep no airing clock, so nothing the app already refreshes on
    /// (launch, reachability, AniList's rollover) lines up with one.
    static let dubLoopInterval: TimeInterval = 3600
    static let dubTitlesPerPass = 8
    static let dubWatchLimit = 200

    /// Only someone who watches dubbed is asked. Compared against the one
    /// value that means it: the stored spelling of "subbed" differs between
    /// platforms ("Subtitled", "Subbed" on tvOS), "Dubbed" does not.
    static var watchesDubbed: Bool {
        UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
    }

    /// The state change for one search, and whether it is news. The first
    /// look at an episode only records: a dub that was already out before
    /// the app ever looked is back catalogue, not an arrival, and announcing
    /// it would fire for every backlogged show on the first run.
    nonisolated static func dubTransition(previous: String?, result: DubCheckResult) -> (next: String?, announce: Bool) {
        switch result {
        case .unknown: return (previous, false)
        case .noDub: return (previous == "out" ? "out" : "waiting", false)
        case .dub: return ("out", previous == "waiting")
        }
    }

    /// Drops entries for titles no longer on the watching list and episodes
    /// the viewer has passed, then caps what is left, oldest keys first.
    nonisolated static func pruneDubWatch(_ watch: [String: String], nextEpisodes: [Int64: Int], limit: Int) -> [String: String] {
        var kept = watch.filter { key, _ in
            let parts = key.split(separator: ":")
            guard parts.count == 2, let id = Int64(parts[0]), let episode = Int(parts[1]),
                  let next = nextEpisodes[id] else { return false }
            return episode >= next
        }
        if kept.count > limit {
            for key in kept.keys.sorted().prefix(kept.count - limit) { kept.removeValue(forKey: key) }
        }
        return kept
    }

    /// Starts the hourly pass once; later calls only run a pass now. Safe to
    /// call from every refresh.
    @MainActor
    func scheduleDubChecks() {
        Task { await checkForNewDubs() }
        guard dubCheckLoopTask == nil else { return }
        dubCheckLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.dubLoopInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.checkForNewDubs()
            }
        }
    }

    /// One pass over the watching list: the next episode of each title
    /// whose Japanese release is out, searched for a dub, one title at a
    /// time so a pass never competes with a play for the indexers.
    @MainActor
    func checkForNewDubs() async {
        guard let engine, Self.watchesDubbed, SystemNotifications.areNewEpisodeNotificationsEnabled,
              !isCheckingDubs else { return }
        isCheckingDubs = true
        defer { isCheckingDubs = false }

        var watch = (UserDefaults.standard.dictionary(forKey: Self.dubWatchKey) as? [String: String]) ?? [:]
        let entries = upNextItems.filter { $0.unit == "EP" }
        let now = Date()
        let due = entries
            .filter { $0.hasNewEpisode && watch["\($0.id):\($0.nextEpisodeOrChapter)"] != "out" }
            .filter { entry in
                dubLastChecked["\(entry.id):\(entry.nextEpisodeOrChapter)"]
                    .map { now.timeIntervalSince($0) >= Self.dubRecheckInterval } ?? true
            }
            .prefix(Self.dubTitlesPerPass)

        for entry in due {
            let key = "\(entry.id):\(entry.nextEpisodeOrChapter)"
            dubLastChecked[key] = now
            let id = entry.id
            let episode = entry.nextEpisodeOrChapter
            let title = entry.title
            let began = Date()
            let result = await Task.detached(priority: .utility) { () -> DubCheckResult in
                guard let choices = try? await engine.listReleaseCandidates(
                    catalog: .anilist, catalogId: id, episode: Int64(episode), title: title
                ), !choices.isEmpty else { return .unknown }
                return choices.contains(where: \.isDub) ? .dub : .noDub
            }.value
            let (next, announce) = Self.dubTransition(previous: watch[key], result: result)
            watch[key] = next
            AppLog.write("[dubcheck] \(id) ep \(episode) \"\(title)\": \(result) in \(Int(Date().timeIntervalSince(began)))s, now \(next ?? "unrecorded")\(announce ? ", announcing" : "")")
            guard announce else { continue }
            let cover = knownCovers[id] ?? entry.thumbnailURL
            Task.detached(priority: .utility) {
                await SystemNotifications.shared.notifyDubOut(
                    catalogId: id, title: title, episode: episode, coverURL: cover
                )
            }
        }

        let nextEpisodes = Dictionary(entries.map { ($0.id, $0.nextEpisodeOrChapter) }, uniquingKeysWith: { a, _ in a })
        // An empty queue is "not loaded yet", as in `notifyAboutNewEpisodes`;
        // pruning against it would forget every `waiting` and swallow the
        // next arrival as a first look.
        if !entries.isEmpty {
            watch = Self.pruneDubWatch(watch, nextEpisodes: nextEpisodes, limit: Self.dubWatchLimit)
        }
        UserDefaults.standard.set(watch, forKey: Self.dubWatchKey)
    }
}
