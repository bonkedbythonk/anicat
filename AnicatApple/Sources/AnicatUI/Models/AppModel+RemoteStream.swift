#if os(iOS)
import Foundation
import AnicatCoreKit

public extension AppModel {
    static let streamFromMacKey = "anicat_stream_from_mac"

    static var isStreamFromMacEnabled: Bool {
        UserDefaults.standard.object(forKey: streamFromMacKey) as? Bool ?? true
    }

    /// Resolves this episode on a Mac and returns a loopback URL the player
    /// can open, or nil to fall back to resolving here.
    ///
    /// Everything that can go wrong -- no Mac in range, never paired with
    /// this one, the Mac refusing, the proxy failing to bind -- returns nil
    /// rather than throwing, because the local engine is a working answer in
    /// every one of those cases. A failure that reaches the viewer is a
    /// failure that did not need to.
    ///
    /// Only the *setup* falls back. A Mac that disappears mid-episode leaves
    /// mpv reading a socket that just died, and there is no way to re-point
    /// it without a visible stop; that surfaces as the ordinary playback
    /// error instead of a silent second resolve.
    func remoteStreamURL(for request: StreamRequest) async -> URL? {
        guard Self.isStreamFromMacEnabled,
              let node = BonjourDiscovery.shared.discoveredMacNode,
              RemoteClient.knownHosts().contains(node.id) else { return nil }

        let ask = StreamAsk(
            catalog: Self.catalogName(request.catalog),
            catalogId: request.catalogId,
            episode: request.episode,
            title: request.title,
            preferDub: request.preferDub,
            chosenName: request.chosenName,
            resumeFraction: request.resumeFraction
        )
        do {
            let grant = try await RemoteClient.shared.resolveOnHost(ask, on: node)
            guard let url = await RemoteStreamProxy.shared.url(for: grant, on: node) else {
                RemoteClient.shared.releaseStream(token: grant.token)
                return nil
            }
            // Released when playback stops, so the Mac stops honouring the
            // token and the file it pinned can age out of the cache again.
            releaseRemoteStream()
            activeRemoteStreamToken = grant.token
            return url
        } catch {
            print("[RemoteStream] falling back to a local resolve: \(error.localizedDescription)")
            return nil
        }
    }

    /// Hands the grant back. Called when playback stops; harmless when there
    /// is nothing outstanding.
    func releaseRemoteStream() {
        guard let token = activeRemoteStreamToken else { return }
        activeRemoteStreamToken = nil
        RemoteStreamProxy.shared.release(token: token)
        RemoteClient.shared.releaseStream(token: token)
    }

    private static func catalogName(_ catalog: FfiCatalog) -> String {
        switch catalog {
        case .anilist: return "anilist"
        case .tmdbMovie: return "tmdb_movie"
        case .tmdbTv: return "tmdb_tv"
        case .mangaDex: return "mangadex"
        }
    }
}
#endif
