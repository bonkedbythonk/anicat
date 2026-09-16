import QuickLook
import SwiftUI

/// Opens the third-party notices the app ships with: the licenses of the Rust
/// crates, MPVKit's libraries, the fonts and the Anime4K shaders.
///
/// Quick Look rather than a `Text` in a sheet, on both platforms: the file is
/// about 500 KB and 10,000 lines, and Quick Look pages and searches a plain
/// text file of that size natively where a SwiftUI `Text` would lay the whole
/// string out at once.
struct AcknowledgementsButton<Label: View>: View {
    @State private var previewURL: URL?
    private let label: Label

    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    var body: some View {
        Button {
            previewURL = Self.noticesURL
        } label: {
            label
        }
        .quickLookPreview($previewURL)
        // Missing only from a bundle built without Resources/Legal; a button
        // that silently did nothing would look like a broken preview.
        .disabled(Self.noticesURL == nil)
    }

    /// Through `anicatResources`, never `Bundle.module`: the generated
    /// accessor fatalErrors inside a packaged Anicat.app.
    static var noticesURL: URL? {
        Bundle.anicatResources.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt", subdirectory: "Legal")
            ?? Bundle.anicatResources.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
    }
}
