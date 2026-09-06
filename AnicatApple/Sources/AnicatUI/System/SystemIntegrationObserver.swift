import SwiftUI

/// A zero-sized view whose only job is to watch three model properties and
/// drive the system integrations off them.
///
/// It exists as a view rather than as `didSet` on the properties themselves
/// because the properties it needs — `upNextItems`, `libraryDownloads`,
/// `currentNavSection` — belong to the parts of `AppModel` the rest of the
/// app writes, and a `didSet` there would put notification and Spotlight
/// work inside the loading path. It is a separate view rather than modifiers
/// on `RootView` so that recomputing the signatures re-evaluates this body
/// and not the whole window's.
public struct SystemIntegrationObserver: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
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
