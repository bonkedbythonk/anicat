import SwiftUI

/// A zero-sized view whose only job is to watch three model properties and
/// drive the system integrations off them.
///
/// It exists as a view rather than as `didSet` on the properties themselves
/// because the properties it needs — `upNextItems`, `libraryDownloads`,
/// `currentNavSection` — belong to the parts of `AppModel` the rest of the
/// app writes, and a `didSet` there would put notification work inside the
/// loading path. It is a separate view rather than modifiers
/// on `RootView` so that recomputing the signatures re-evaluates this body
/// and not the whole window's.
public struct SystemIntegrationObserver: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    @State private var reachability = NetworkReachability()
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            // Mounted in both platform branches of `AnicatApp`, which makes
            // it the one place a reconnect hook reaches macOS and iOS alike.
            #if os(iOS)
            // The cache cap is sized for playback — an episode plus its N+1
            // preload is most of 3 GiB — which is the right budget while
            // watching and the wrong one for a phone that has stopped. The
            // playing torrent is exempt inside the engine, so backgrounding
            // mid-episode with audio still running keeps what it is reading.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                Task { await model.purgeStreamCache() }
            }
            #endif
            .task {
                reachability.start {
                    // Quietly: this fires while the viewer is looking at
                    // whatever the failed load left behind, and a loading
                    // spinner over it would be the second interruption.
                    Task { await model.refreshAll(showLoading: false) }
                }
            }
            .onChange(of: model.systemIntegrationSignature, initial: true) { _, _ in
                model.refreshSystemIntegrations()
            }
            .onChange(of: model.downloadSignature, initial: true) { _, _ in
                model.handleDownloadsChanged()
            }
            .onChange(of: model.currentNavSection) { _, _ in
                model.updateDockBadge()
            }
    }
}
