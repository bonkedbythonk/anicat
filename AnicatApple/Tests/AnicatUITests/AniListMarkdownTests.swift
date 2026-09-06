import Testing
import Foundation
import SwiftUI
@testable import AnicatUI

@Suite("AniList markdown conversion")
struct AniListMarkdownTests {
    private func intents(_ text: AttributedString) -> [(String, InlinePresentationIntent?)] {
        text.runs.map { (String(text[$0.range].characters), $0.inlinePresentationIntent) }
    }

    @Test("A spoiler becomes its own block and never leaks its markers")
    func spoilerBlock() {
        let blocks = AniListMarkdown.parse("She survives. ~!He does not.!~ The end.")
        #expect(blocks.count == 3)
        #expect(blocks[0].plainText == "She survives.")
        guard case .spoiler(let inner) = blocks[1] else {
            Issue.record("expected the middle block to be a spoiler, got \(blocks[1])")
            return
        }
        #expect(inner.map(\.plainText) == ["He does not."])
        #expect(blocks[2].plainText == "The end.")
        #expect(!blocks.contains { $0.plainText.contains("~!") || $0.plainText.contains("!~") })
    }

    @Test("An unterminated spoiler hides everything after it rather than dropping it")
    func unterminatedSpoiler() {
        let blocks = AniListMarkdown.parse("Safe. ~!Everything after this is a spoiler.")
        #expect(blocks.count == 2)
        #expect(blocks[0].plainText == "Safe.")
        guard case .spoiler(let inner) = blocks[1] else {
            Issue.record("expected a spoiler block, got \(blocks[1])")
            return
        }
        #expect(inner.map(\.plainText) == ["Everything after this is a spoiler."])
    }

    @Test("img tags of every width become image blocks, never visible markup")
    func imageTags() {
        let blocks = AniListMarkdown.parse("Before img220(https://example.com/a.jpg) after img(https://example.com/b.png)")
        let images = blocks.compactMap { block -> URL? in
            if case .image(let url) = block { return url }
            return nil
        }
        #expect(images.map(\.absoluteString) == ["https://example.com/a.jpg", "https://example.com/b.png"])
        let text = blocks.map(\.plainText).joined(separator: " ")
        #expect(!text.contains("img220"))
        #expect(!text.contains("https://"))
        #expect(text.contains("Before"))
        #expect(text.contains("after"))
    }

    @Test("Bold, italic and underline are applied and their markers removed")
    func inlineEmphasis() {
        let text = AniListMarkdown.inline("plain **bold** and *italic* and __underline__ done")
        let plain = String(text.characters)
        #expect(plain == "plain bold and italic and underline done")
        #expect(!plain.contains("*"))
        #expect(!plain.contains("_"))

        let bold = intents(text).first { $0.0 == "bold" }
        #expect(bold?.1?.contains(.stronglyEmphasized) == true)

        let italic = intents(text).first { $0.0 == "italic" }
        #expect(italic?.1?.contains(.emphasized) == true)

        let underlined = text.runs.first { String(text[$0.range].characters) == "underline" }
        #expect(underlined?.underlineStyle == .single)
    }

    @Test("Nested emphasis carries both intents")
    func nestedEmphasis() {
        let text = AniListMarkdown.inline("**bold *and italic* here**")
        #expect(String(text.characters) == "bold and italic here")
        let both = text.runs.first { String(text[$0.range].characters) == "and italic" }
        #expect(both?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(both?.inlinePresentationIntent?.contains(.emphasized) == true)
    }

    @Test("Underscores inside a word or a bare URL are not emphasis markers")
    func underscoresInsideWords() {
        let url = AniListMarkdown.inline("see https://example.com/a_b_c for more")
        #expect(String(url.characters) == "see https://example.com/a_b_c for more")

        let identifier = AniListMarkdown.inline("the resolve_stream call")
        #expect(String(identifier.characters) == "the resolve_stream call")
    }

    @Test("A link keeps its label and drops its target from the text")
    func links() {
        let text = AniListMarkdown.inline("see [the wiki](https://example.com/wiki) for more")
        #expect(String(text.characters) == "see the wiki for more")
        let link = text.runs.first { String(text[$0.range].characters) == "the wiki" }
        #expect(link?.link?.absoluteString == "https://example.com/wiki")
    }

    @Test("Literal <br> tags become line breaks, not visible markup")
    func lineBreaks() {
        let blocks = AniListMarkdown.parse("First line<br>second line<br />third line")
        #expect(blocks.count == 1)
        #expect(blocks[0].plainText == "First line\nsecond line\nthird line")
        #expect(!blocks[0].plainText.contains("<br"))
    }

    @Test("Blank lines split paragraphs, and empty input yields nothing")
    func paragraphs() {
        let blocks = AniListMarkdown.parse("One.\n\nTwo.\n\n\nThree.")
        #expect(blocks.map(\.plainText) == ["One.", "Two.", "Three."])
        #expect(AniListMarkdown.parse(nil).isEmpty)
        #expect(AniListMarkdown.parse("   \n  ").isEmpty)
    }
}

@Suite("Relative timestamps")
struct RelativeTimestampTests {
    @Test("Compact units, and a future timestamp never reads as negative")
    func relativeShort() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(SumiTimeFormatter.relativeShort(from: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(SumiTimeFormatter.relativeShort(from: now.addingTimeInterval(-600), now: now) == "10m ago")
        #expect(SumiTimeFormatter.relativeShort(from: now.addingTimeInterval(-7_200), now: now) == "2h ago")
        #expect(SumiTimeFormatter.relativeShort(from: now.addingTimeInterval(-172_800), now: now) == "2d ago")
        #expect(SumiTimeFormatter.relativeShort(from: now.addingTimeInterval(1_000), now: now) == "just now")
        #expect(SumiTimeFormatter.relativeShort(unixSeconds: 1_699_996_400, now: now) == "1h ago")
    }
}
