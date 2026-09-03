import Testing
@testable import AnicatUI

@Suite("Sumi Ledger & Anime4K Tests")
struct AnicatUITests {
    @Test("Anime4K Preset Shader Count")
    func testPresetShaders() {
        let preset = Anime4KPreset.modeAFast
        #expect(preset.shaderFileNames.count == 6)
        #expect(preset.shaderFileNames.first == "Anime4K_Clamp_Highlights.glsl")
    }

    @Test("Sumi Ledger Tokens")
    func testThemeTokens() {
        #expect(SumiTheme.radiusMd == 10)
        #expect(SumiTheme.spaceLg == 24)
    }
}
