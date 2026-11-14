import SwiftUI

/// Anicat's own icons ("index cut"). Every SF Symbol name the app draws has a
/// custom symbol of the same name in `Resources/Symbols.xcassets`, generated
/// from `scripts/symbols/icons.swift` by `scripts/build-symbols.sh`. A name
/// missing from the catalog renders nothing and logs nothing, so a new icon
/// starts with a drawing there, not with a name here.
///
/// The bundle is resolved once: `Bundle.anicatResources` builds a path and
/// stats it on every call, and these initialisers run on every view update.
private let symbolBundle = Bundle.anicatResources

extension Image {
    public init(anicat name: String) {
        self.init(name, bundle: symbolBundle)
    }
}

extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, anicat name: String) {
        self.init { Text(titleKey) } icon: { Image(anicat: name) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, anicat name: String) {
        self.init { Text(title) } icon: { Image(anicat: name) }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    public init(_ titleKey: LocalizedStringKey, anicat name: String, description: Text? = nil) {
        self.init { SwiftUI.Label(titleKey, anicat: name) } description: { description }
    }
}
