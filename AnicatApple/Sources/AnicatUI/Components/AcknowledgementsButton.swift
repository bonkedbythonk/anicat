#if canImport(QuickLook)
import QuickLook
#endif
import SwiftUI

/// Opens the third-party notices the app ships with: the licenses of the Rust
/// crates, MPVKit's libraries, the fonts and the Anime4K shaders.
///
/// Quick Look rather than a `Text` in a sheet, on the Mac and the phone: the
/// file is about 500 KB and 10,000 lines, and Quick Look pages and searches
/// a plain text file of that size natively where a SwiftUI `Text` would lay
/// the whole string out at once. tvOS has no Quick Look, so there the same
/// button presents the notices in a scrolling sheet, paginated by `List`
/// rows so the layout is a screen at a time rather than the whole file.
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
        #if canImport(QuickLook)
        .quickLookPreview($previewURL)
        #else
        .sheet(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            NoticesSheet(url: previewURL)
        }
        #endif
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

#if !canImport(QuickLook)
/// The notices on Apple TV: one `List` row per line, so a 10,000-line file
/// is laid out lazily and the remote scrolls it a page at a time.
private struct NoticesSheet: View {
    let url: URL?

    @State private var lines: [String] = []

    var body: some View {
        NavigationStack {
            List(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 20, design: .monospaced))
            }
            .navigationTitle("Acknowledgements")
        }
        .task {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            lines = text.components(separatedBy: "\n")
        }
    }
}
#endif
