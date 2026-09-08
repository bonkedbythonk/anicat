import Testing
import Foundation
@testable import AnicatUI

@Suite("Theme palettes")
struct ThemePaletteTests {
    // MARK: Helpers

    /// The channels of an `#RRGGBB` string, or nil if it is not one. A token
    /// that fails to parse is not a test failure by itself — `Color(hex:)`
    /// answers opaque black for anything it cannot read, which is why a typo
    /// in a hex string ships as a plausible-looking colour instead of a crash.
    private func channels(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.first == "#", hex.count == 7 else { return nil }
        let body = hex.dropFirst()
        guard body.allSatisfy({ $0.isHexDigit }) else { return nil }
        var int: UInt64 = 0
        Scanner(string: String(body)).scanHexInt64(&int)
        return (
            Double((int >> 16) & 0xFF),
            Double((int >> 8) & 0xFF),
            Double(int & 0xFF)
        )
    }

    /// `foreground` at `alpha` painted over `background`, as a hex string.
    /// Source-over in sRGB, which is what the compositor actually does to
    /// `SumiTheme.muted` and `SumiTheme.border` on screen — those two are the
    /// only tokens whose contrast is a function of the ground beneath them.
    private func composite(_ foreground: String, alpha: Double, over background: String) -> String {
        guard let fore = channels(foreground), let back = channels(background) else { return "#000000" }
        let r = Int((fore.r * alpha + back.r * (1 - alpha)).rounded())
        let g = Int((fore.g * alpha + back.g * (1 - alpha)).rounded())
        let b = Int((fore.b * alpha + back.b * (1 - alpha)).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// The floor body text has to clear on each palette. AA large / AAA normal
    /// for the two dark skins, which is what Ink already measured at; Paper
    /// gets the AA normal bar because a light ground with a near-black ink is
    /// held to the same standard the rest of the system is.
    private func foregroundFloor(_ palette: SumiPalette) -> Double {
        palette.isLight ? 4.5 : 7.0
    }

    // MARK: The WCAG helper itself

    @Test("the luminance helper reproduces the two ends of the WCAG scale")
    func contrastEndpoints() {
        // Black on white is 21:1 by definition, and any colour against itself
        // is 1:1. A helper that gets the sRGB linearisation wrong still lands
        // near these, so the mid-scale check below is the one with teeth.
        #expect(abs(SumiPalette.contrastRatio("#FFFFFF", "#000000") - 21.0) < 0.01)
        #expect(abs(SumiPalette.contrastRatio("#8FB8DC", "#8FB8DC") - 1.0) < 0.001)
        // #767676 on white is the canonical 4.54:1 example from the WCAG
        // "contrast (minimum)" understanding document.
        #expect(abs(SumiPalette.contrastRatio("#767676", "#FFFFFF") - 4.54) < 0.02)
        // Symmetric: the ratio does not depend on which side is the ground.
        #expect(
            SumiPalette.contrastRatio("#26221B", "#F1ECE2")
                == SumiPalette.contrastRatio("#F1ECE2", "#26221B")
        )
    }

    // MARK: Every palette carries a usable value for every token

    @Test("every palette parses every token and separates its ground from its card")
    func tokensAreDistinctAndParseable() {
        for palette in SumiPalette.all {
            let tokens: [(String, String)] = [
                ("background", palette.backgroundHex),
                ("card", palette.cardHex),
                ("foreground", palette.foregroundHex),
                ("indigo", palette.indigoHex),
                ("indigoLight", palette.indigoLightHex)
            ]
            for (name, hex) in tokens {
                #expect(channels(hex) != nil, "\(palette.id).\(name) is not an #RRGGBB string: \(hex)")
            }

            // A card that matches its ground is the failure a palette written
            // by copy-paste actually produces: every surface in the app loses
            // its edge and only the 1px border says a card is there at all.
            #expect(
                palette.cardHex.uppercased() != palette.backgroundHex.uppercased(),
                "\(palette.id) draws its cards in the ground colour"
            )
            #expect(palette.mutedAlpha > 0 && palette.mutedAlpha < 1)
            #expect(palette.borderAlpha > 0 && palette.borderAlpha < 1)
        }

        // Three palettes, three distinct grounds. Two skins that resolve to the
        // same background are one skin with two names in the picker.
        let grounds = Set(SumiPalette.all.map { $0.backgroundHex.uppercased() })
        #expect(grounds.count == SumiPalette.all.count)
    }

    // MARK: Contrast

    @Test("body text clears its palette's contrast floor")
    func foregroundContrast() {
        for palette in SumiPalette.all {
            let floor = foregroundFloor(palette)
            // Measured: Ink 15.04, OLED 17.06, Paper 13.44.
            #expect(
                palette.foregroundContrast >= floor,
                "\(palette.id) foreground is \(palette.foregroundContrast):1, floor \(floor):1"
            )
        }
    }

    @Test("serif headings are Sakura's alone")
    func serifHeadings() {
        // The palette's only non-colour axis. A skin that picks it up by
        // accident changes every page title in the app, which no contrast
        // check would catch.
        #expect(SumiPalette.sakura.usesSerifHeadings)
        #expect(SumiPalette.sakuraLight.usesSerifHeadings)
        for palette in [SumiPalette.ink, .paper, .oled] {
            #expect(palette.usesSerifHeadings == false, "\(palette.id) grew serif headings")
        }
    }

    @Test("the accent stays readable on its own ground")
    func accentContrast() {
        // Ink's #8FB8DC over Paper's off-white measures 1.77:1 — the reason
        // Paper carries its own darker accent instead of inheriting one.
        // Measured at the shipped values: Ink 8.86, Paper 6.27, OLED 10.06.
        for palette in SumiPalette.all {
            #expect(
                palette.accentContrast >= 4.5,
                "\(palette.id) accent is \(palette.accentContrast):1 on its ground"
            )
        }
    }

    @Test("muted text survives being composited onto its ground")
    func mutedContrast() {
        // `muted` is the foreground at 55-65% alpha, so its real contrast is
        // against the ground it is painted over, not against the foreground
        // hex. Measured: Ink 5.24, OLED 5.79, Paper 4.64 — Paper is the one
        // with no room, which is why its alpha is 0.65 and not 0.55.
        for palette in SumiPalette.all {
            let flattened = composite(palette.foregroundHex, alpha: palette.mutedAlpha, over: palette.backgroundHex)
            let ratio = SumiPalette.contrastRatio(flattened, palette.backgroundHex)
            #expect(ratio >= 4.5, "\(palette.id) muted text is \(ratio):1 on its ground")
        }
    }

    @Test("hairline borders stay visible on every ground")
    func borderVisibility() {
        // OLED raises the border alpha from 0.10 to 0.18 for exactly this: at
        // 0.10 over #000000 the composited hairline is #181716 at 1.17:1,
        // which an OLED panel renders as very nearly the unlit ground beside
        // it. Measured at the shipped alphas: Ink 1.27, Paper 1.31, OLED 1.46.
        for palette in SumiPalette.all {
            let flattened = composite(palette.foregroundHex, alpha: palette.borderAlpha, over: palette.backgroundHex)
            let ratio = SumiPalette.contrastRatio(flattened, palette.backgroundHex)
            #expect(ratio >= 1.2, "\(palette.id) border is \(ratio):1 against its ground")
        }
    }

    // MARK: Selection

    @Test("a skin plus an appearance resolves to a palette, and OLED stays dark")
    func skinResolution() {
        #expect(SumiSkin.ink.palette(isLight: false).id == "ink")
        #expect(SumiSkin.ink.palette(isLight: true).id == "paper")
        #expect(SumiSkin.sakura.palette(isLight: false).id == "sakura")
        #expect(SumiSkin.sakura.palette(isLight: true).id == "sakura-light")

        // OLED is a statement about the panel, and there is no light ground
        // that switches pixels off. Asking for Light has to land back on its
        // own dark rather than on some other skin's paper.
        #expect(SumiSkin.oled.hasLight == false)
        #expect(SumiSkin.oled.palette(isLight: true).id == "oled")

        #expect(AnicatAppearance.system.isLight(systemIsDark: true) == false)
        #expect(AnicatAppearance.system.isLight(systemIsDark: false))
        #expect(AnicatAppearance.light.isLight(systemIsDark: true))
        #expect(AnicatAppearance.dark.isLight(systemIsDark: false) == false)

        // The stored values are the raw values; a rename would silently reset
        // every existing user to the default.
        #expect(SumiSkin(rawValue: "ink") == .ink)
        #expect(SumiSkin(rawValue: "sakura") == .sakura)
        #expect(SumiSkin(rawValue: "oled") == .oled)
        #expect(AnicatAppearance(rawValue: "system") == .system)
        #expect(ThemeStore.skinKey == "anicat_skin")
        #expect(ThemeStore.appearanceKey == "anicat_appearance")
    }

    @Test("the old single key migrates to a skin and an appearance")
    func legacyMigration() {
        // Paper and Sakura Light were their own entries before the split.
        // Anyone sitting on one of them has to come back as the light half of
        // the skin they were actually looking at, not as its dark.
        #expect(LegacyAnicatTheme.ink.migrated == (skin: .ink, appearance: .dark))
        #expect(LegacyAnicatTheme.paper.migrated == (skin: .ink, appearance: .light))
        #expect(LegacyAnicatTheme.oled.migrated == (skin: .oled, appearance: .dark))
        #expect(LegacyAnicatTheme.sakura.migrated == (skin: .sakura, appearance: .dark))
        #expect(LegacyAnicatTheme.sakuraLight.migrated == (skin: .sakura, appearance: .light))
        #expect(LegacyAnicatTheme.system.migrated == (skin: .ink, appearance: .system))

        #expect(ThemeStore.legacyKey == "anicat_theme")
        #expect(LegacyAnicatTheme(rawValue: "sakuraLight") == .sakuraLight)
    }

    @Test("colorScheme follows the palette's own ground, not the system's")
    func colorSchemeFollowsPalette() {
        #expect(SumiPalette.ink.isLight == false)
        #expect(SumiPalette.oled.isLight == false)
        #expect(SumiPalette.paper.isLight == true)
    }

    @Test("the accent override replaces the accent without touching the rest")
    func accentOverrideHook() {
        var palette = SumiPalette.ink
        #expect(palette.accentOverride == nil)
        // The hook the poster accent will use. `indigoHex` stays the palette's
        // own, which is what keeps `accentContrast` measuring something real.
        palette.accentOverride = palette.successLight
        #expect(palette.indigoHex == SumiPalette.ink.indigoHex)
        #expect(palette.accentContrast == SumiPalette.ink.accentContrast)
    }
}
