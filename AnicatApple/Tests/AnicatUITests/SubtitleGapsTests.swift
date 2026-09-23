import Testing
import Foundation
@testable import AnicatUI

@Suite("Subtitle gaps")
struct SubtitleGapsTests {
    typealias Line = SubtitleGaps.Line

    /// A line of talk every `every` seconds from `from` to `to`, 3 s long.
    func talk(_ from: Double, _ to: Double, every: Double = 5, style: String = "Default") -> [Line] {
        stride(from: from, to: to, by: every).map { Line(start: $0, end: $0 + 3, style: style, text: "Line at \(Int($0))") }
    }

    func verdict(_ lines: [Line], italic: Set<String> = []) -> SubtitleGaps.Verdict {
        SubtitleGaps.verdict(dialogue: SubtitleGaps.dialogue(lines, italicStyles: italic), from: 0, to: 480).verdict
    }

    @Test("Talk all the way through has no room for a song")
    func continuous() {
        #expect(verdict(talk(0, 480)) == .absent)
    }

    @Test("A 90-second hole is an opening's room, at the start or in the middle")
    func hole() {
        #expect(verdict(talk(0, 60) + talk(150, 480)) == .plausible)
        #expect(verdict(talk(95, 480)) == .plausible)
    }

    @Test("Signs and songs over the opening do not fill its hole")
    func signsDoNotCount() {
        let opening = talk(60, 150, every: 4, style: "Signs") + talk(60, 150, every: 4, style: "OP1R")
            + talk(60, 150, every: 4, style: "ED1 - ROM")
        #expect(verdict(talk(0, 60) + opening + talk(150, 480)) == .plausible)
    }

    @Test("Lyrics in a dialogue style: romaji over translation at the same moment")
    func stackedLyrics() {
        let lyrics = stride(from: 60.0, to: 150, by: 5).flatMap {
            [Line(start: $0, end: $0 + 4, style: "On Top", text: "romaji \(Int($0))"),
             Line(start: $0, end: $0 + 4, style: "Default", text: "translation \(Int($0))")]
        }
        #expect(verdict(talk(0, 60) + lyrics + talk(150, 480)) == .plausible)
    }

    @Test("Lyrics in a dialogue style: set in italic, by tag or by the style")
    func italicLyrics() {
        let tagged = stride(from: 60.0, to: 150, by: 5).map {
            Line(start: $0, end: $0 + 4, style: "Default", text: "{\\i1}I can't stand still \(Int($0)){\\i0}")
        }
        #expect(verdict(talk(0, 60) + tagged + talk(150, 480)) == .plausible)
        let styled = talk(60, 150, style: "DefaultItalics")
        #expect(verdict(talk(0, 60) + styled + talk(150, 480), italic: ["DefaultItalics"]) == .plausible)
    }

    @Test("Karaoke and notes are songs")
    func karaoke() {
        let k = stride(from: 60.0, to: 150, by: 5).map {
            Line(start: $0, end: $0 + 4, style: "Default", text: "{\\k20}la{\\k30}la \(Int($0))")
        }
        let notes = stride(from: 62.0, to: 150, by: 5).map {
            Line(start: $0, end: $0 + 2, style: "Default", text: "♪ humming \(Int($0))")
        }
        #expect(verdict(talk(0, 60) + k + notes + talk(150, 480)) == .plausible)
    }

    @Test("Too few dialogue lines to judge: a signs-only track")
    func signsOnly() {
        #expect(verdict(talk(0, 480, every: 30, style: "Signs")) == .unknown)
        #expect(verdict(talk(0, 60, every: 10)) == .unknown)
    }

    @Test("Style names", arguments: [
        ("Default", true), ("DefaultItalics", true), ("On Top", true), ("GJM_Main_1080p", true),
        ("Irumakun - Default", true), ("Flashback - Italics", true), ("main - top", true),
        ("Signs", false), ("OP1R", false), ("OPv2", false), ("ED1 - ROM", false), ("English ED", false),
        ("Default - Signs", false), ("Songs_Insert", false), ("Show_Title", false), ("BD DX", false),
    ])
    func styles(name: String, dialogue: Bool) {
        #expect(SubtitleGaps.isDialogueStyle(name) == dialogue)
    }

    @Test("Italic detection follows the tags and the style")
    func italics() {
        #expect(SubtitleGaps.isWhollyItalic("{\\i1}Thinking.{\\i0}", styleItalic: false))
        #expect(SubtitleGaps.isWhollyItalic("{\\i1}From how he's dressed,{\\i0}\\N{\\i1}an athlete.{\\i0}", styleItalic: false))
        #expect(!SubtitleGaps.isWhollyItalic("{\\i1}Half{\\i0} and half", styleItalic: false))
        #expect(SubtitleGaps.isWhollyItalic("Plain text", styleItalic: true))
        #expect(!SubtitleGaps.isWhollyItalic("{\\i0}Upright", styleItalic: true))
        #expect(!SubtitleGaps.isWhollyItalic("{\\iclip(0,0,10,10)}Clipped", styleItalic: false))
    }

    @Test("Italic styles come from the header")
    func header() {
        let header = """
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline
        Style: Default,Roboto Medium,52,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0
        Style: DefaultItalics,Roboto Medium,52,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,-1,0
        """
        #expect(SubtitleGaps.italicStyles(header: header) == ["DefaultItalics"])
    }
}

/// Reads a real file through libavformat. Needs a local episode, so it runs
/// only when `ANICAT_SUBTITLE_TEST_FILE` names one.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANICAT_SUBTITLE_TEST_FILE"] != nil))
func subtitleExtractorReadsAFile() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ANICAT_SUBTITLE_TEST_FILE"])
    for (start, length) in [(0.0, 480.0), (1120.0, 300.0)] {
        let began = Date()
        let tracks = try #require(await SubtitleExtractor.extract(url: path, start: start, length: length))
        let chosen = try #require(SubtitleExtractor.dialogueTrack(tracks))
        let verdict = SubtitleGaps.verdict(dialogue: chosen.dialogue, from: start, to: start + length)
        print("\(Int(start))-\(Int(start + length))s: \(tracks.count) tracks, \(chosen.track.lines.count) lines, \(chosen.dialogue.count) dialogue, \(verdict) in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
        #expect(!chosen.track.lines.isEmpty)
        #expect(chosen.track.lines.allSatisfy { $0.end > start && $0.start <= start + length })
    }
}

/// The whole classifier over a folder of `.ass` files, one verdict per line
/// on stdout, for checking a change against a corpus (the one `SubtitleGaps`
/// was measured on came from AnimeTosho's extracted attachments). Runs only
/// when `ANICAT_SUBTITLE_CORPUS` names the folder.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANICAT_SUBTITLE_CORPUS"] != nil))
func subtitleGapsOverACorpus() async throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ANICAT_SUBTITLE_CORPUS"]))
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "ass" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in files {
        let tracks = try #require(await SubtitleExtractor.extract(url: file.path, start: 0, length: 480))
        let verdict = SubtitleExtractor.dialogueTrack(tracks).map {
            SubtitleGaps.verdict(dialogue: $0.dialogue, from: 0, to: 480)
        }
        print("corpus \(file.lastPathComponent) \(verdict.map { "\($0.verdict) \($0.longestGap.map { Int($0) } ?? -1)" } ?? "no-track")")
    }
}
