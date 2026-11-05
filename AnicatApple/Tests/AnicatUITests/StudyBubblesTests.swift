import Testing
import Foundation
@testable import AnicatUI

@Suite("Study mode OCR results")
struct StudyBubblesTests {
    // The shape mokuro 0.2 writes, with made-up text.
    private let volume = """
    {"version": "0.2.4", "title": "manga", "volume": "x", "pages": [
      {"img_path": "x/002.jpg", "img_width": 800, "img_height": 1200, "blocks": [
        {"box": [400, 120, 480, 420], "vertical": true, "font_size": 20,
         "lines_coords": [], "lines": ["今日は早く", "帰ってくるね．．．"]},
        {"box": [10, 10, 20, 20], "vertical": true, "font_size": 20,
         "lines_coords": [], "lines": ["  "]}
      ]},
      {"img_path": "x/010.jpg", "img_width": 800, "img_height": 1200, "blocks": []}
    ]}
    """

    @Test("A page's index comes from the file name, and boxes become page fractions")
    func parsesPagesAndBoxes() throws {
        let bubbles = try MokuroResult.bubbles(from: Data(volume.utf8))
        let page = try #require(bubbles[2])
        #expect(page.count == 1)
        #expect(page[0].text == "今日は早く帰ってくるね…")
        #expect(page[0].rect == CGRect(x: 0.5, y: 0.1, width: 0.1, height: 0.25))
        #expect(bubbles[10]?.isEmpty == true)
    }

    @Test("Full-width full stops used as an ellipsis become one ellipsis")
    func cleansEllipses() {
        #expect(MokuroResult.clean(["待ってる．．"]) == "待ってる…")
        #expect(MokuroResult.clean(["そうだな", "～"]) == "そうだな～")
    }
}
