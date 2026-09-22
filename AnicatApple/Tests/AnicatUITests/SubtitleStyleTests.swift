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
        #expect(SubtitleStyle.release.assOverrides.isEmpty)
        let opts = Dictionary(uniqueKeysWithValues: SubtitleStyle.release.textOptions)
        #expect(opts["sub-font"] == "sans-serif")
        #expect(opts["sub-border-style"] == "outline-and-shadow")
    }

    @Test("A preset restyles dialogue styles by name and never touches a sign style")
    func presetsAreNamed() {
        let overrides = SubtitleStyle.simulcast.assOverrides.split(separator: ",").map(String.init)
        #expect(overrides.contains("Default.Fontname=Trebuchet MS"))
        #expect(overrides.contains("Main.PrimaryColour=&H00FFFFFF"))
        // Every field is scoped to a style: a bare `Fontname=` would hit
        // every style in the file, signs included.
        #expect(overrides.allSatisfy { $0.split(separator: "=")[0].contains(".") })
        #expect(!overrides.contains { $0.hasPrefix("Sign.") || $0.hasPrefix("TS.") || $0.hasPrefix("Title.") })
    }

    @Test("Boxed draws a box, the others an outline")
    func boxed() {
        let boxed = Dictionary(uniqueKeysWithValues: SubtitleStyle.boxed.textOptions)
        #expect(boxed["sub-border-style"] == "opaque-box")
        #expect(SubtitleStyle.boxed.assOverrides.contains("Default.BorderStyle=3"))
        #expect(SubtitleStyle.streaming.assOverrides.contains("Default.BorderStyle=1"))
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
            let overrides = mpv_set_property_string(handle, "sub-ass-style-overrides", style.assOverrides)
            #expect(overrides >= 0, "\(style): sub-ass-style-overrides -> \(String(cString: mpv_error_string(overrides)))")
            for (name, value) in style.textOptions {
                let status = mpv_set_property_string(handle, name, value)
                #expect(status >= 0, "\(style): \(name)=\(value) -> \(String(cString: mpv_error_string(status)))")
            }
        }
    }
}
#endif
