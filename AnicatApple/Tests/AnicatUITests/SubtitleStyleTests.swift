import Testing
import Foundation
@testable import AnicatUI

@Suite("Subtitle styles")
struct SubtitleStyleTests {
    @Test("ASS colours are &HAABBGGRR with alpha as transparency")
    func assColour() {
        #expect(SubtitleStyle.assColour(0xFFFFFFFF) == "&H00FFFFFF")
        #expect(SubtitleStyle.assColour(0xFF000000) == "&H00000000")
        // Opaque yellow: red and green full, blue low, bytes reversed.
        #expect(SubtitleStyle.assColour(0xFFFFE62E) == "&H002EE6FF")
        // 0xB0 opacity is 0x4F transparency.
        #expect(SubtitleStyle.assColour(0xB0000000) == "&H4F000000")
    }

    @Test("The release default clears overrides and restores mpv's text defaults")
    func releaseDefault() {
        #expect(SubtitleStyle.release.assOverrides().isEmpty)
        let opts = Dictionary(uniqueKeysWithValues: SubtitleStyle.release.textOptions)
        #expect(opts["sub-font"] == "sans-serif")
        #expect(opts["sub-border-style"] == "outline-and-shadow")
    }

    @Test("A preset restyles dialogue styles by name and never touches a sign style")
    func presetsAreNamed() {
        let overrides = SubtitleStyle.simulcast.assOverrides(styles: ["Default", "Main"])
            .split(separator: ",").map(String.init)
        #expect(overrides.contains("Default.Fontname=Trebuchet MS"))
        #expect(overrides.contains("Main.PrimaryColour=&H00FFFFFF"))
        // Every field is scoped to a style: a bare `Fontname=` would hit
        // every style in the file, signs included.
        #expect(overrides.allSatisfy { $0.split(separator: "=")[0].contains(".") })
        #expect(!overrides.contains { $0.hasPrefix("Sign.") || $0.hasPrefix("TS.") || $0.hasPrefix("Title.") })
    }

    @Test("Sizes and widths are scaled into the file's own script height")
    func scaledToScript() {
        func field(_ overrides: String, _ name: String) -> String? {
            overrides.split(separator: ",").first { $0.hasPrefix("Default.\(name)=") }
                .map { String($0.split(separator: "=")[1]) }
        }
        // The classic values in a 360-line script: size 24, outline 2, shadow 1.
        let at360 = SubtitleStyle.simulcast.assOverrides(playResY: 360)
        #expect(field(at360, "Fontsize") == "24")
        #expect(field(at360, "Outline") == "2")
        #expect(field(at360, "Shadow") == "1")
        // The same look in a 1080-line BD script is three times the numbers.
        let at1080 = SubtitleStyle.simulcast.assOverrides(playResY: 1080)
        #expect(field(at1080, "Fontsize") == "72")
        #expect(field(at1080, "Outline") == "6")
        // A preset with no size of its own leaves the release's.
        #expect(field(SubtitleStyle.streaming.assOverrides(playResY: 360), "Fontsize") == nil)
    }

    @Test("Fill mode lifts only the dialogue, by the crop, in the file's own lines")
    func liftedForFill() {
        // 16:9 filled on a 2.17:1 screen loses 9.1% off each edge.
        let lifted = SubtitleStyle.release.assOverrides(playResY: 360, styles: ["Default", "DefaultItalicsTop"], liftingBy: 0.091)
            .split(separator: ",").map(String.init)
        #expect(lifted.contains("Default.MarginV=55"))
        #expect(lifted.contains("DefaultItalicsTop.MarginV=55"))
        #expect(lifted.allSatisfy { $0.contains(".MarginV=") })
        #expect(!lifted.contains { $0.hasPrefix("Sign.") })
        #expect(SubtitleStyle.release.assOverrides(playResY: 1080, liftingBy: 0.091).contains("Default.MarginV=167"))
        // A preset keeps its look and gains the margin.
        let preset = SubtitleStyle.simulcast.assOverrides(playResY: 360, liftingBy: 0.091)
        #expect(preset.contains("Default.Fontname=Trebuchet MS"))
        #expect(preset.contains("Default.MarginV=55"))
        #expect(!SubtitleStyle.simulcast.assOverrides(playResY: 360).contains("MarginV"))
    }

    @Test("Script height is read the way libass defaults it")
    func playResY() {
        #expect(SubtitleStyle.playResY(fromHeader: "[Script Info]\nPlayResX: 640\nPlayResY: 360\n") == 360)
        #expect(SubtitleStyle.playResY(fromHeader: "PlayResX: 1280\n") == 1024)
        #expect(SubtitleStyle.playResY(fromHeader: "PlayResX: 1920\n") == 1440)
        #expect(SubtitleStyle.playResY(fromHeader: "[Script Info]\nTitle: x\n") == 288)
    }

    /// `Style:` lines as the releases wrote them, cut to name, font, size.
    private func header(_ styles: String...) -> String {
        "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour\n"
            + styles.map { "Style: \($0),&H00FFFFFF" }.joined(separator: "\n")
    }

    @Test("Dialogue styles come from the header: the main style's font and size, signs out")
    func dialogueStylesFromHeader() {
        // SubsPlease, Watari-kun 26.
        let subsPlease = header(
            "Default,Roboto Medium,26", "DefaultItalics,Roboto Medium,26", "DefaultTop,Roboto Medium,26",
            "Flashback,Roboto Medium,26", "Narration,Roboto Medium,26", "Signs,Arial,24",
            "Signs_PhoneW,Arial,18", "Credits2,Arial,13")
        #expect(SubtitleStyle.dialogueStyles(fromHeader: subsPlease)
            == ["Default", "DefaultItalics", "DefaultTop", "Flashback", "Narration"])
        // `On Top` carried 53 lines an episode between restyled `Default` ones.
        #expect(SubtitleStyle.dialogueStyles(fromHeader: header(
            "Default,Roboto Medium,26", "OS,Arial,18", "On Top,Roboto Medium,26", "Italics,Roboto Medium,26"))
            == ["Default", "On Top", "Italics"])
        // An unused `Default` in another size: the show's own family anchors.
        #expect(SubtitleStyle.dialogueStyles(fromHeader: header(
            "Default,Roboto Medium,22", "Irumakun - Default,Roboto Medium,26", "Irumakun - Flashback  Top,Roboto Medium,26",
            "sign_11525_110_I_thought,Roboto Medium,26", "Iruma - Ep Title,Trebuchet MS,20"))
            == ["Default", "Irumakun - Default", "Irumakun - Flashback  Top"])
        // `Main` inside a longer name; the group's other font stays out.
        #expect(SubtitleStyle.dialogueStyles(fromHeader: header(
            "GJM_Main_1080p,Gandhi Sans,75", "GJM_Overlap_1080p,Gandhi Sans,75", "OP,Cute Dino,58"))
            == ["GJM_Main_1080p", "GJM_Overlap_1080p"])
        // No dialogue-sounding name at all: the first style anchors.
        #expect(SubtitleStyle.dialogueStyles(fromHeader: header(
            "BD DX,Arial,20", "BD Top DX,Arial,20", "BD Top Right,Verdana Bold,20"))
            == ["BD DX", "BD Top DX"])
        // A sign style in the dialogue's own font is still a sign style.
        #expect(SubtitleStyle.dialogueStyles(fromHeader: header(
            "Default,Alegreya Fake,72", "Alt,Alegreya Fake,72", "MarySigns,Alegreya Fake,72"))
            == ["Default", "Alt"])
        // A plain-text track has no header.
        #expect(SubtitleStyle.dialogueStyles(fromHeader: "").isEmpty)
    }

    @Test("Boxed draws a box, the others an outline")
    func boxed() {
        let boxed = Dictionary(uniqueKeysWithValues: SubtitleStyle.boxed.textOptions)
        #expect(boxed["sub-border-style"] == "opaque-box")
        #expect(SubtitleStyle.boxed.assOverrides().contains("Default.BorderStyle=3"))
        #expect(SubtitleStyle.streaming.assOverrides().contains("Default.BorderStyle=1"))
    }

    @Test("An unknown stored value reads as the release default")
    func unknownStored() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SubtitleStyle.key)
        defer { if let saved { defaults.set(saved, forKey: SubtitleStyle.key) } else { defaults.removeObject(forKey: SubtitleStyle.key) } }
        defaults.set("neon", forKey: SubtitleStyle.key)
        #expect(SubtitleStyle.current == .release)
        defaults.removeObject(forKey: SubtitleStyle.key)
        #expect(SubtitleStyle.current == .release)
    }
}

#if os(macOS)
import Libmpv

/// Against the libmpv this app links, not the manual: an option the
/// bundled mpv does not know fails silently in `setSubtitleStyle`, and the
/// preset would half-apply with nothing in the log to say why.
///
/// On the main actor because `mpv_initialize` on macOS builds mpv's own
/// AppKit pieces (a Touch Bar, system symbol images). Run from the test
/// pool it deadlocked on the Objective-C class-initialisation lock against
/// `SnapshotTests`, which renders AppKit views on the main thread at the
/// same moment; the app itself only ever creates mpv on the main thread.
@Suite("Subtitle styles against the bundled libmpv")
@MainActor
struct SubtitleStyleMpvTests {
    @Test("Every option and value each style sets is accepted")
    func libmpvAcceptsEveryOption() throws {
        let handle = try #require(mpv_create())
        defer { mpv_terminate_destroy(handle) }
        mpv_set_option_string(handle, "vo", "null")
        mpv_set_option_string(handle, "ao", "null")
        #expect(mpv_initialize(handle) >= 0)
        for style in SubtitleStyle.allCases {
            let overrides = mpv_set_property_string(handle, "sub-ass-style-overrides", style.assOverrides(playResY: 1080))
            #expect(overrides >= 0, "\(style): sub-ass-style-overrides -> \(String(cString: mpv_error_string(overrides)))")
            for (name, value) in style.textOptions {
                let status = mpv_set_property_string(handle, name, value)
                #expect(status >= 0, "\(style): \(name)=\(value) -> \(String(cString: mpv_error_string(status)))")
            }
        }
        // Most names the header finds carry spaces ("On Top", "BD DX",
        // "Irumakun - Flashback  Top"); a list that split or trimmed them
        // would select those styles and restyle none.
        let spaced = SubtitleStyle.simulcast.assOverrides(styles: ["On Top", "Irumakun - Flashback  Top"])
        #expect(mpv_set_property_string(handle, "sub-ass-style-overrides", spaced) >= 0)
        let readBack = try #require(mpv_get_property_string(handle, "sub-ass-style-overrides"))
        defer { mpv_free(readBack) }
        #expect(String(cString: readBack) == spaced)
    }
}
#endif
