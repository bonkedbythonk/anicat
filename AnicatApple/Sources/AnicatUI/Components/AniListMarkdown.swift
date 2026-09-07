import SwiftUI

/// AniList's bios, staff descriptions and forum posts are not Markdown and
/// not HTML — they are a house dialect with `~!spoiler!~` blocks, `img(url)`
/// and `img220(url)` tags, and literal `<br>` mixed into otherwise
/// Markdown-ish text. `AttributedString(markdown:)` renders none of those:
/// it leaves `~!`, `!~`, `img220(https://...)` and `<br>` on screen as
/// visible markup, which is how every one of them reached the user before
/// this existed.
///
/// The parser is a pure function over value types on purpose: a converter
/// that returned a `View` could not be unit-tested, and the spoiler and
/// image rules are exactly the parts worth testing.
public enum AniListMarkdown {
    public indirect enum Block: Equatable {
        case paragraph(AttributedString)
        /// Hidden until the reader asks for it. Nested blocks rather than a
        /// flat string because a spoiler routinely wraps several paragraphs
        /// and sometimes an image.
        case spoiler([Block])
        case image(URL)

        /// The rendered text with no attributes, for tests and for anything
        /// that needs a plain summary of a block.
        public var plainText: String {
            switch self {
            case .paragraph(let text):
                return String(text.characters)
            case .spoiler(let inner):
                return inner.map(\.plainText).joined(separator: "\n")
            case .image:
                return ""
            }
        }
    }

    /// `img`, `img220`, `img500` — the digits are a width hint AniList's own
    /// renderer honours, and leaving them out of the pattern is what let
    /// `img220(https://...)` through as literal text.
    private static let imageTagPattern = try? NSRegularExpression(
        pattern: #"img\d*\(\s*(https?://[^)\s]+)\s*\)"#,
        options: [.caseInsensitive]
    )

    private static let lineBreakPattern = try? NSRegularExpression(
        pattern: #"<br\s*/?>"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ raw: String?) -> [Block] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let normalized = normalizeLineBreaks(raw)
        return splitSpoilers(normalized).flatMap { segment -> [Block] in
            let inner = plainBlocks(from: segment.text)
            guard !inner.isEmpty else { return [] }
            return segment.isSpoiler ? [.spoiler(inner)] : inner
        }
    }

    static func normalizeLineBreaks(_ text: String) -> String {
        let unixed = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let lineBreakPattern else { return unixed }
        let range = NSRange(unixed.startIndex..<unixed.endIndex, in: unixed)
        return lineBreakPattern.stringByReplacingMatches(in: unixed, range: range, withTemplate: "\n")
    }

    /// Splits on `~!` / `!~`. An unterminated `~!` spoils everything after
    /// it rather than dropping it: the text is what the author wrote, and
    /// showing it anyway is the failure the marker exists to prevent.
    static func splitSpoilers(_ text: String) -> [(isSpoiler: Bool, text: String)] {
        var segments: [(isSpoiler: Bool, text: String)] = []
        var rest = Substring(text)
        while let open = rest.range(of: "~!") {
            let before = rest[rest.startIndex..<open.lowerBound]
            if !before.isEmpty { segments.append((false, String(before))) }
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: "!~") {
                segments.append((true, String(afterOpen[afterOpen.startIndex..<close.lowerBound])))
                rest = afterOpen[close.upperBound...]
            } else {
                segments.append((true, String(afterOpen)))
                rest = Substring("")
                break
            }
        }
        if !rest.isEmpty { segments.append((false, String(rest))) }
        return segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One spoiler-free segment into paragraphs and images, in source order.
    private static func plainBlocks(from segment: String) -> [Block] {
        var blocks: [Block] = []
        var cursor = segment.startIndex

        func appendParagraphs(_ text: Substring) {
            for chunk in text.components(separatedBy: "\n\n") {
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                blocks.append(.paragraph(inline(trimmed)))
            }
        }

        if let imageTagPattern {
            let full = NSRange(segment.startIndex..<segment.endIndex, in: segment)
            for match in imageTagPattern.matches(in: segment, range: full) {
                guard let matchRange = Range(match.range, in: segment),
                      let urlRange = Range(match.range(at: 1), in: segment) else { continue }
                appendParagraphs(segment[cursor..<matchRange.lowerBound])
                if let url = URL(string: String(segment[urlRange])) {
                    blocks.append(.image(url))
                }
                cursor = matchRange.upperBound
            }
        }
        appendParagraphs(segment[cursor...])
        return blocks
    }

    private struct InlineStyle: OptionSet {
        let rawValue: Int
        static let bold = InlineStyle(rawValue: 1 << 0)
        static let italic = InlineStyle(rawValue: 1 << 1)
        static let underline = InlineStyle(rawValue: 1 << 2)
    }

    /// `**bold**`, `__underline__`, `*italic*`/`_italic_` and `[text](url)`.
    /// Hand-rolled rather than handed to `AttributedString(markdown:)`
    /// because that parser treats `__` as strong emphasis, not underline,
    /// and throws on the malformed link syntax AniList posts are full of —
    /// and a throw here means the whole bio renders as raw source.
    static func inline(_ text: String) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var style: InlineStyle = []
        let chars = Array(text)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            var intent: InlinePresentationIntent = []
            if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if style.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if style.contains(.underline) { run.underlineStyle = .single }
            result += run
            buffer = ""
        }

        func matches(_ marker: String, at index: Int) -> Bool {
            let markerChars = Array(marker)
            guard index + markerChars.count <= chars.count else { return false }
            return Array(chars[index..<(index + markerChars.count)]) == markerChars
        }

        while i < chars.count {
            if matches("**", at: i) {
                flush()
                style.formSymmetricDifference(.bold)
                i += 2
                continue
            }
            if matches("__", at: i) {
                flush()
                style.formSymmetricDifference(.underline)
                i += 2
                continue
            }
            // A single `*`/`_` only opens or closes emphasis at a word
            // boundary. Without the check, the underscores in a bare
            // `https://example.com/a_b_c` — which forum comments are full
            // of — were eaten as italic markers and the link came out as
            // `https://example.com/abc`, silently wrong rather than ugly.
            if (chars[i] == "*" || chars[i] == "_") && isEmphasisBoundary(chars, at: i) {
                flush()
                style.formSymmetricDifference(.italic)
                i += 1
                continue
            }
            if chars[i] == "[", let link = parseLink(chars, from: i) {
                flush()
                var run = AttributedString(link.label)
                if let url = URL(string: link.destination) { run.link = url }
                run.foregroundColor = SumiTheme.indigo
                result += run
                i = link.end
                continue
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
        return result
    }

    /// True when at least one side of the marker is not alphanumeric, which
    /// is what separates `*italic*` from the `_` inside a URL or an
    /// identifier.
    private static func isEmphasisBoundary(_ chars: [Character], at index: Int) -> Bool {
        let before = index > 0 ? chars[index - 1] : " "
        let after = index + 1 < chars.count ? chars[index + 1] : " "
        return !before.isLetter && !before.isNumber || !after.isLetter && !after.isNumber
    }

    private static func parseLink(_ chars: [Character], from start: Int) -> (label: String, destination: String, end: Int)? {
        var i = start + 1
        var label = ""
        while i < chars.count, chars[i] != "]" {
            label.append(chars[i])
            i += 1
        }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        i += 2
        var destination = ""
        while i < chars.count, chars[i] != ")" {
            destination.append(chars[i])
            i += 1
        }
        guard i < chars.count, chars[i] == ")" else { return nil }
        return (label, destination, i + 1)
    }
}

// MARK: - Rendering

/// Renders `AniListMarkdown.Block`s in the page's own type ramp. Spoilers
/// come up blurred behind a tap target, so a bio never spoils a show the
/// reader opened the page to decide whether to watch.
public struct AniListMarkdownText: View {
    private let blocks: [AniListMarkdown.Block]
    private let font: Font
    private let color: Color
    private let lineSpacing: CGFloat

    public init(
        _ raw: String?,
        font: Font = .system(size: 13),
        color: Color = SumiTheme.foreground.opacity(0.85),
        lineSpacing: CGFloat = 4
    ) {
        self.blocks = AniListMarkdown.parse(raw)
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
    }

    public var body: some View {
        content.textSelection(.enabled)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: AniListMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .image(let url):
            CachedAsyncImage(url: url, maxPixelSize: 480) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd).fill(SumiTheme.card)
            }
            .frame(maxWidth: 260, maxHeight: 360, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        case .spoiler(let inner):
            SpoilerBlock(font: font, color: color, lineSpacing: lineSpacing, blocks: inner)
        }
    }
}

private struct SpoilerBlock: View {
    let font: Font
    let color: Color
    let lineSpacing: CGFloat
    let blocks: [AniListMarkdown.Block]

    @State private var isRevealed = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { isRevealed = true }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if case .paragraph(let text) = block {
                        Text(text)
                            .font(font)
                            .foregroundColor(color)
                            .lineSpacing(lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if case .image(let url) = block {
                        CachedAsyncImage(url: url, maxPixelSize: 480) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd).fill(SumiTheme.card)
                        }
                        .frame(maxWidth: 260, maxHeight: 360, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .blur(radius: isRevealed ? 0 : 7)
            .opacity(isRevealed ? 1 : 0.45)
            .padding(10)
            .background(SumiTheme.card.opacity(isRevealed ? 0 : 1))
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(alignment: .center) {
                if !isRevealed {
                    Text("Spoiler — click to reveal")
                        .sumiTabularMono(size: 10.5, weight: .medium)
                        .foregroundColor(SumiTheme.indigo)
                }
            }
            .overlay {
                if !isRevealed {
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .disabled(isRevealed)
    }
}
