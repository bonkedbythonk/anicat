import Foundation
import AnicatCoreKit

extension AppModel {
    /// Called from the 85% mark of an episode with no episode after it. Looks
    /// the sequel up then, not at the end, so the card has its answer ready
    /// for the last 30 seconds. The offer is also filed in
    /// `pendingNextSeasons`: a closed or minimized player never shows the
    /// card, and the home row is where it is found afterwards.
    func prepareNextSeasonOffer(catalogId: Int64, episode: Int) async {
        guard let engine, isSignedIn else { return }
        do {
            let detail = try await engine.mediaDetail(catalogId: catalogId, isManga: false)
            guard NextSeason.isFinale(episode: episode, total: detail.episodeCount.map(Int.init)),
                  let sequel = detail.sequel,
                  !NextSeason.dismissedIds().contains(sequel.catalogId) else { return }
            let sequelDetail = try await engine.mediaDetail(catalogId: sequel.catalogId, isManga: false)
            guard NextSeason.isOfferable(listStatus: sequelDetail.listStatus) else { return }
            let offer = NextSeasonOffer(
                sequelId: sequel.catalogId,
                title: sequel.title,
                coverImage: sequel.coverImage,
                sourceId: catalogId,
                sourceTitle: detail.title,
                isReleased: sequelDetail.status != "NOT_YET_RELEASED"
            )
            AppLog.write("[nextseason] \(catalogId) finished, offering \(offer.sequelId) (released \(offer.isReleased))")
            if currentPlaybackCatalogId == catalogId {
                nextSeasonOffer = offer
                nextSeasonCardHidden = false
            }
            if !pendingNextSeasons.contains(where: { $0.sequelId == offer.sequelId }) {
                pendingNextSeasons.append(offer)
                NextSeason.savePending(pendingNextSeasons)
            }
        } catch {
            // Silent: the offer is a convenience, and the next finished
            // season looks again.
            AppLog.write("[nextseason] lookup for \(catalogId) failed: \(error)")
        }
    }

    /// Puts the sequel on the list (Watching, or Planning while unaired) and
    /// retires the offer. Does not play it.
    func addNextSeasonToList(_ offer: NextSeasonOffer) async {
        guard let engine else { return }
        do {
            let current = try await engine.mediaDetail(catalogId: offer.sequelId, isManga: false).listStatus
            if let status = NextSeason.statusToWrite(listStatus: current, isReleased: offer.isReleased) {
                try await engine.updateListEntry(catalogId: offer.sequelId, status: status, score: nil, progress: nil)
                recordAniListSuccess()
            }
            retireNextSeason(offer)
            refreshListsAfterEdit()
        } catch {
            recordAniListFailure(error)
        }
    }

    /// The end card's Watch: list first, then episode 1 of the new season.
    func watchNextSeason(_ offer: NextSeasonOffer) {
        Task {
            await addNextSeasonToList(offer)
            guard offer.isReleased else { return }
            playFromShelf(
                model: self,
                catalogId: offer.sequelId,
                episode: 1,
                title: offer.title,
                coverURL: URL(string: offer.coverImage)
            )
        }
    }

    /// "Dismiss" on the home row: never offered again for this sequel.
    func dismissNextSeason(_ offer: NextSeasonOffer) {
        NextSeason.rememberDismissed(offer.sequelId)
        retireNextSeason(offer)
    }

    private func retireNextSeason(_ offer: NextSeasonOffer) {
        pendingNextSeasons.removeAll { $0.sequelId == offer.sequelId }
        NextSeason.savePending(pendingNextSeasons)
        if nextSeasonOffer?.sequelId == offer.sequelId { nextSeasonOffer = nil }
    }

    /// Drops pending offers whose sequel the viewer has since started,
    /// finished, dropped or paused by hand, so the home row never offers
    /// what is already on the list. Run with the home refresh.
    func reconcilePendingNextSeasons() async {
        guard let engine, isSignedIn, !pendingNextSeasons.isEmpty else { return }
        for offer in pendingNextSeasons {
            guard let detail = try? await engine.mediaDetail(catalogId: offer.sequelId, isManga: false) else { continue }
            if !NextSeason.isOfferable(listStatus: detail.listStatus) { retireNextSeason(offer) }
        }
    }
}
