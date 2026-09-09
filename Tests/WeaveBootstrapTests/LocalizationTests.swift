import Foundation
import Testing
import Weave

@Test
func test_layoutDirectionResolver_mapsRTLLocales_withoutPlatformGlobals() {
    #expect(LayoutDirectionResolver.resolve(locale: Locale(identifier: "ar")) == .rightToLeft)
    #expect(LayoutDirectionResolver.resolve(locale: Locale(identifier: "he_IL")) == .rightToLeft)
    #expect(LayoutDirectionResolver.resolve(locale: Locale(identifier: "en_US")) == .leftToRight)
}

@Test
func test_layoutDirectionResolver_explicitOverrideWins_andEnvironmentUsesIt() {
    #expect(
        LayoutDirectionResolver.resolve(locale: Locale(identifier: "ar"), override: .leftToRight)
            == .leftToRight)

    var values = EnvironmentValues()
    values.locale = Locale(identifier: "ar")
    #expect(values.layoutDirection == .rightToLeft)
    values.layoutDirectionOverride = .leftToRight
    #expect(values.layoutDirection == .leftToRight)
}

@Test @MainActor
func test_localeAndDirectionKeys_invalidateLayoutAndDisplay() {
    let scope = EnvironmentScope()
    let localeChange = scope.set(LocaleKey.self, Locale(identifier: "ar"))
    let directionChange = scope.set(LayoutDirectionKey.self, .leftToRight)

    #expect(localeChange.invalidation == .layoutAndDisplay)
    #expect(directionChange.invalidation == .layoutAndDisplay)
    #expect(scope.snapshot.values.layoutDirection == .leftToRight)
}

@Test
@MainActor
func catalogLocalizationFormatsPluralFallbackAndPseudo() {
    let provider = CatalogLocalizationProvider(
        catalog: LocalizationCatalog(
            tables: ["Localizable": ["welcome": "Hello, %1$@"]],
            plurals: ["Localizable": ["items": ["one": "%1$@ item", "other": "%1$@ items"]]]
        ))
    let welcome = provider.resolve(
        LocalizedText(key: "welcome", fallback: "Fallback", arguments: [.string("Ada")]),
        locale: Locale(identifier: "en_US")
    )
    #expect(welcome.text == "Hello, Ada")
    let plural = provider.resolve(
        LocalizedText(key: "items", fallback: "Fallback", arguments: [.integer(2)]),
        locale: Locale(identifier: "en_US")
    )
    #expect(plural.text == "2 items")
    let missing = provider.resolve(
        LocalizedText(key: "missing", fallback: "Fallback"), locale: Locale(identifier: "ar")
    )
    #expect(missing.usedFallback)
    #expect(missing.diagnostic?.key == "missing")
    #expect(
        provider.resolve(
            LocalizedText(key: "welcome", fallback: "Fallback"),
            locale: Locale(identifier: "en_US"), pseudo: true
        ).text.hasPrefix("［"))
}

@Test
@MainActor
func localizationStoreEmitsOnlyDistinctLocaleChanges() {
    let store = LocalizationStore(
        locale: Locale(identifier: "en_US"), provider: CatalogLocalizationProvider())
    #expect(!store.setLocale(Locale(identifier: "en_US")))
    #expect(store.setLocale(Locale(identifier: "ar")))
    #expect(store.revision == 1)
}
