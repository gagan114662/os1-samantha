import Testing
@testable import OS1

struct TerminalThemeTests {
    @Test
    func defaultOS1TerminalUsesDarkHighContrastBackground() {
        let appearance = TerminalThemePreference.defaultValue.resolvedAppearance

        #expect(appearance.style == .os1)
        #expect(appearance.backgroundColor.red < 0.12)
        #expect(appearance.backgroundColor.green < 0.12)
        #expect(appearance.backgroundColor.blue < 0.12)
        #expect(appearance.foregroundColor.red > 0.9)
        #expect(appearance.foregroundColor.green > 0.85)
        #expect(appearance.foregroundColor.blue > 0.8)
    }

    @Test
    func presetSelectionProducesStablePresetAppearance() {
        let preference = TerminalThemePreference().selectingPreset(.dusk)
        let appearance = preference.resolvedAppearance

        #expect(appearance.style == .dusk)
        #expect(appearance.name == "Dusk")
        #expect(appearance.paletteStyle == .dusk)
        #expect(!appearance.isCustom)
        #expect(appearance.ansiPalette.count == 16)
    }

    @Test
    func customBackgroundPreservesPresetPaletteAndForeground() {
        let customBackground = TerminalThemeColor(hex: 0x010203)
        let preference = TerminalThemePreference(style: .evergreen)
            .updatingBackgroundColor(customBackground)
        let appearance = preference.resolvedAppearance

        #expect(preference.style == .custom)
        #expect(appearance.style == .custom)
        #expect(appearance.isCustom)
        #expect(appearance.backgroundColor == customBackground)
        #expect(appearance.paletteStyle == .evergreen)
        #expect(appearance.foregroundColor == TerminalThemePreference(style: .evergreen).resolvedAppearance.foregroundColor)
        #expect(appearance.ansiPalette.count == 16)
    }

    @Test
    func customForegroundKeepsExistingCustomBackground() {
        let customBackground = TerminalThemeColor(hex: 0x112233)
        let customForeground = TerminalThemeColor(hex: 0xF0E0D0)
        let preference = TerminalThemePreference(style: .paper)
            .updatingBackgroundColor(customBackground)
            .updatingForegroundColor(customForeground)
        let appearance = preference.resolvedAppearance

        #expect(preference.style == .custom)
        #expect(appearance.backgroundColor == customBackground)
        #expect(appearance.foregroundColor == customForeground)
        #expect(appearance.paletteStyle == .paper)
        #expect(appearance.isCustom)
    }
}
