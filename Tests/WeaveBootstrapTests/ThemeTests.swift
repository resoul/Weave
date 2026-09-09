import Testing
import Weave

private let testTheme = Theme(
    id: "test",
    colors: ThemeColors(
        background: ThemeColor(red: 0, green: 0, blue: 0),
        surface: ThemeColor(red: 0.1, green: 0.1, blue: 0.1),
        primary: ThemeColor(red: 1, green: 0, blue: 0),
        secondary: ThemeColor(red: 0, green: 1, blue: 0),
        accent: ThemeColor(red: 0, green: 0, blue: 1), text: ThemeColor(red: 1, green: 1, blue: 1),
        textSecondary: ThemeColor(red: 0.7, green: 0.7, blue: 0.7),
        border: ThemeColor(red: 0.4, green: 0.4, blue: 0.4),
        error: ThemeColor(red: 1, green: 0, blue: 0),
        success: ThemeColor(red: 0, green: 1, blue: 0),
        warning: ThemeColor(red: 1, green: 1, blue: 0)
    ),
    typography: Typography(pointSize: 20, affectsMeasure: true)
)

@Test @MainActor
func test_themeStore_updatesRootScope_withoutOverwritingChildOverride() async {
    let root = EnvironmentScope()
    let child = EnvironmentScope(parent: root)
    child.set(ThemeKey.self, testTheme)
    let store = ThemeStore()
    await store.apply(testTheme, to: root)
    #expect(root.snapshot.values.theme == testTheme)
    #expect(child.snapshot.values.theme == testTheme)
}

@Test @MainActor
func test_themeAndContentSizeCategory_haveExpectedInvalidation() {
    #expect(ThemeKey.invalidation == .layoutAndDisplay)
    #expect(ColorSchemeKey.invalidation == .layoutAndDisplay)
    #expect(ContentSizeCategoryKey.invalidation == .layout)
    var values = EnvironmentValues()
    values.contentSizeCategory = .accessibilityLarge
    #expect(values.contentSizeCategory == .accessibilityLarge)
}

@Test @MainActor
func test_colorSchemeRemainsRaw_andThemeCommitIsAtomic() async {
    let scope = EnvironmentScope()
    let palette = ThemePalette.standard
    let store = ThemeStore(palette: palette)

    #expect(scope.snapshot.values.colorScheme == .unspecified)
    await store.apply(scheme: .dark, to: scope)

    let snapshot = scope.snapshot
    #expect(snapshot.values.colorScheme == .dark)
    #expect(snapshot.values.theme == palette.resolved(for: .dark))
}

@Test
func test_themePaletteBuilderResolvesLightAndDark() {
    let light = Theme.defaultValue.colors
    let dark = ThemeColors.standardDark
    let palette = ThemePalette(id: "custom") {
        $0.light = light
        $0.dark = dark
    }

    #expect(palette.resolved(for: .light).colors == light)
    #expect(palette.resolved(for: .dark).colors == dark)
    #expect(palette.resolved(for: .unspecified).colors == light)
}

@Test
func test_themeColorAndTypography_normalizeInvalidValues() {
    let color = ThemeColor(red: .infinity, green: -1, blue: 0.5, alpha: .nan)
    #expect(color.red == 0)
    #expect(color.green == 0)
    #expect(color.blue == 0.5)
    #expect(color.alpha == 0)
    #expect(Typography(pointSize: -.infinity).pointSize == 0)
}
