import SwiftUI

/// TMDB's logo and the sentence their API terms require beside it.
///
/// Not decoration and not a courtesy: the terms make both the mark and the
/// wording conditions of using the API at all, and they also say the mark
/// must sit *less prominently* than the marks that identify the app itself --
/// which is why this is a 14pt line at the foot of a page rather than
/// anything in the rail or a header.
///
/// The mark ships as a PNG rasterised from TMDB's own `blue_short` SVG.
/// Neither AppKit nor UIKit decodes an SVG handed to it as a loose bundle
/// resource -- only an asset catalog compiled by Xcode does, and this package
/// has none -- so the SVG would have loaded as nothing at all, exactly as the
/// sidebar mark did before it was read from a URL.
public struct TMDBAttribution: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            if let mark = Self.mark {
                mark
                    .resizable()
                    .scaledToFit()
                    .frame(height: 14)
                    .accessibilityLabel("The Movie Database")
            }

            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.system(size: 11))
                .foregroundColor(SumiTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Loaded by URL rather than by name, for the same reason `SumiLogoMark`
    /// is: `Image(_:bundle:)` looks the name up in an asset catalog, and this
    /// ships as a loose PNG, so the by-name form renders nothing and says
    /// nothing about why.
    private static let mark: Image? = {
        let candidates = [
            Bundle.module.url(forResource: "tmdb_logo", withExtension: "png"),
            Bundle.module.url(forResource: "tmdb_logo", withExtension: "png", subdirectory: "Images"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let image = PlatformImage(data: data) {
                return Image(platformImage: image)
            }
        }
        return nil
    }()
}
